#' Install (Mini)conda 
#'
#' Install conda - specifically Miniconda, though historically we used Anaconda - to an appropriate destination path,
#' skipping the installation if said path already exists.
#'
#' @param installed Logical scalar indicating whether \pkg{basilisk} is already installed.
#' Should only be set to \code{FALSE} in \pkg{basilisk} \code{configure} scripts.
#' 
#' @details
#' This function was originally created from code in \url{https://github.com/hafen/rminiconda},
#' also borrowing code from \pkg{reticulate}'s \code{install_miniconda} for correct Windows installation.
#' It downloads and runs a Miniconda installer to create a dedicated Conda instance that is managed by \pkg{basilisk},
#' separate from other instances that might be available on the system.
#'
#' The installer itself is cached to avoid re-downloading it when, e.g., re-installing \pkg{basilisk} across separate R sessions.
#' Users can obtain/delete the cached installer by looking at the contents of the parent directory of \code{\link{getExternalDir}}.
#' This caching behavior is disabled for system installations (see \code{\link{useSystemDir}}), which touch nothing except the system directories;
#' in such cases, only repeated installation attempts in the same R session will re-use the same installer.
#'
#' Currently, we use version 4.12.0 of the Miniconda3 installer, which also comes with Python 3.9.
#' Users can change this by setting the \code{BASILISK_MINICONDA_VERSION} environment variable, e.g., to \code{"py38_4.11.0"}.
#' Any change should be done with a great deal of caution, typically due to some system-specific problem with a particular Miniconda version.
#' If it must be done, users should try to stick to the same Python version.
#'
#' @section Destruction of old instances:
#' Whenever \code{installConda} is re-run and \code{BASILISK_USE_SYSTEM_DIR} is not set, 
#' any old conda instances and their associated \pkg{basilisk} environments are deleted from the external installation directory.
#' This avoids duplication of large conda instances after their obselescence.
#' Client packages are expected to recreate their environments in the latest conda instance.
#'
#' Users can disable this destruction by setting the \code{BASILISK_NO_DESTROY} environment variable to \code{"1"}.
#' This may be necessary on rare occasions when running multiple R instances on the same Bioconductor release.
#' Note that setting this variable is not required for R instances using different Bioconductor releases;
#' the destruction process is smart enough to only remove conda instances generated from the same release.
#'
#' @section Skipping the fallback R:
#' When \code{BASILISK_USE_SYSTEM_DIR} is set, \code{installConda} will automatically create a conda environment with its own copy of R.
#' This is used as the \dQuote{last resort fallback} for running \pkg{reticulate} code in the presence of shared library incompatibilities with the main R installation.
#' If users know that no incompatibilities exist in their application, they can set the \code{BASILISK_NO_FALLBACK_R} variable to \code{"1"}.
#' This will instruct \code{installConda} to skip the creation of the fallback environment, saving some time and disk space. 
#'
#' @return
#' A conda instance is created at the location specified by \code{\link{getCondaDir}}.
#' Nothing is performed if a complete instance already exists at that location.
#' A logical scalar is returned indicating whether a new instance was created.
#'  
#' @author Aaron Lun
#'
#' @examples
#' # We can't actually run installConda() here, as it 
#' # either relies on basilisk already being installed or
#' # it has a hard-coded path to the basilisk system dir.
#' print("dummy test to pass BiocCheck")
#'
#' @export
#' @importFrom dir.expiry touchDirectory
installConda <- function(installed=TRUE) {
    if (!is.na(.get_external_conda())) {
        return(FALSE)
    }

    dest_path <- getCondaDir(installed=installed)

    is.system <- useSystemDir()
    if (!is.system) {
        # Locking the installation; this ensures we will wait for any
        # concurrently running installations to finish. For system installs,
        # this isn't necessary as the R package locks take care of it.
        loc <- lockExternalDir(exclusive=!file.exists(dest_path))
        on.exit(unlockExternalDir(loc))

        # Do NOT assign the existence of dest_path to a variable for re-use in the
        # locking call above. We want to recheck existance just in case the
        # directory was created after waiting to acquire the lock.
        if (file.exists(dest_path)) {
            touchDirectory(getExternalDir())
            return(FALSE)
        }
    } else {
        if (!file.exists(dest_path)) {
            # If we're assuming that basilisk is installed, and we're using a system
            # directory, and the conda installation directory is missing, something
            # is clearly wrong. We check this here instead of in `getCondaDir()` to
            # avoid throwing after an external install, given that `installConda()`
            # is usually called before `getCondaDir()`.
            if (installed) {
                stop("conda should have been installed during basilisk installation")
            }
        } else {
            return(FALSE)
        }
    }

    host <- dirname(dest_path)
    unlink2(host) 
    dir.create2(host)

    # Destroying the directory upon failure, to avoid difficult interpretations
    # of any remnant installation directories when this function is hit again.
    success <- FALSE
    on.exit({
        if (!success) {
            unlink2(dest_path, recursive=TRUE)
        }
    }, add=TRUE, after=FALSE)

    if (!identical(Sys.getenv("BASILISK_USE_MINIFORGE", NA), "0")) {
        prefix <- "Miniforge3"
        version <- Sys.getenv("BASILISK_MINIFORGE_VERSION", "24.3.0-0")
        base_url <- paste0("https://github.com/conda-forge/miniforge/releases/download/", version)
    } else {
        prefix <- "Miniconda3"
        version <- Sys.getenv("BASILISK_MINICONDA_VERSION", "py39_4.12.0")
        base_url <- "https://repo.anaconda.com/miniconda"
    }

    if (isWindows()) {
        if (.Machine$sizeof.pointer != 8) {
            stop("Windows 32-bit architectures not supported by basilisk")
        }
        inst_file <- sprintf("%s-%s-Windows-x86_64.exe", prefix, version)
        tmploc <- .expedient_download(file.path(base_url, inst_file))

        parent <- dirname(dest_path)
        if (!file.exists(parent)) {
            dir.create2(parent)
        }
        sanitized_path <- gsub("/", "\\\\", dest_path) # Windows installer doesn't like forward slashes.

        inst_args <- c("/InstallationType=JustMe", "/RegisterPython=0", "/S", sprintf("/D=%s", sanitized_path))
        Sys.chmod(tmploc, mode = "0755")
        status <- system2(tmploc, inst_args)

    } else if (isMacOSX()) {
        arch <- if (isMacOSXArm()) "arm64" else "x86_64" 
        inst_file <- sprintf("%s-%s-MacOSX-%s.sh", prefix, version, arch)
        tmploc <- .expedient_download(file.path(base_url, inst_file))
        inst_args <- sprintf(" %s -b -p %s", tmploc, dest_path)
        status <- system2("bash", inst_args)

    } else {
        arch <- if (isLinuxAarch64()) "aarch64" else "x86_64"
        inst_file <- sprintf("%s-%s-Linux-%s.sh", prefix, version, arch)
        tmploc <- .expedient_download(file.path(base_url, inst_file))
        inst_args <- sprintf(" %s -b -p %s", tmploc, dest_path)
        status <- system2("bash", inst_args)
    }

    # Rigorous checks for proper installation, heavily inspired if not outright
    # copied from reticulate::install_miniconda.
    if (status != 0) {
        stop(sprintf("conda installation failed with status code '%s'", status))
    }

    conda.exists <- file.exists(getCondaBinary(dest_path))
    if (conda.exists && isWindows()) {
        # Sometimes Windows doesn't create this file. Why? WHO KNOWS.
        conda.exists <- file.exists(file.path(dest_path, "condabin/conda.bat"))
    }

    python.cmd <- getPythonBinary(dest_path)
    report <- system2(python.cmd, c("-E", "-c", shQuote("print(1)")), stdout=TRUE, stderr=FALSE)
    if (!conda.exists || report!="1") {
        stop("conda installation failed for an unknown reason")
    }

    # Installing reticulate into the base basilisk environment, 
    # to enable fallback execution upon GLIBCXX mismatch.
    if (is.system && !noFallbackR()) {
        .install_fallback_r(dest_path)
    }

    if (is.system) {
        # Cleaning the system install, because we're never going to use the
        # cache again; clients use their own cache directories. We need to
        # specify the directory manually otherwise conda goes looking in
        # ~/.conda/pkgs, and a system install shouldn't touch that.
        old <- setCondaPackageDir(file.path(dest_path, "pkgs"))
        on.exit(setCondaPackageDir(old), add=TRUE, after=FALSE)
        cleanConda(dest_path)
    } else {
        # We (indirectly) call dir.expiry::unlockDirectory on exit, which will
        # automatically implement the clearing logic; so there's no need to
        # explicitly call clearExternalDir here.
        touchDirectory(getExternalDir())
    }

    success <- TRUE
    TRUE 
}

#' @importFrom utils download.file
#' @importFrom methods is
.expedient_download <- function(url) {
    if (useSystemDir()) {
        dir <- tempdir()
    } else {
        dir <- dirname(getExternalDir())
    }

    fname <- file.path(dir, basename(url))
    if (!file.exists(fname)) {
        tryCatch({
            if (download.file(url, fname, mode="wb")) {
                stop("failed to download the conda installer - check your internet connection or increase 'options(timeout=...)'") 
            }
        }, error=function(e) {
            unlink(fname, force=TRUE)
            stop(e)
        })
    }

    fname
}
