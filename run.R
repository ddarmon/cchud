#!/usr/bin/env Rscript
# cchud — Claude Code Heads-Up Display launcher
# -------------------------------------------------------------------------
# Boots ../app.R and opens it in a chromeless Chromium ("--app") window so it
# behaves like a standalone desktop app rather than another browser tab.
#
# Quitting:
#   - With {callr} installed (recommended): the Shiny server runs in a
#     background process and is killed automatically when you close the window.
#   - Without {callr}: the window opens but closing it leaves the server
#     running; stop it with Ctrl-C in the terminal (or close the terminal).
#
# Run directly:  Rscript run.R     (or double-click cchud.command / cchud.bat)

PORT <- 4747L
URL  <- sprintf("http://127.0.0.1:%d", PORT)

# --- locate app.R (same folder as this script) ----------------------------
this_file <- local({
  a <- commandArgs(FALSE)
  f <- sub("^--file=", "", a[grepl("^--file=", a)])
  if (length(f)) normalizePath(f[1]) else NA_character_
})
script_dir <- if (!is.na(this_file)) dirname(this_file) else normalizePath(getwd())
app_dir    <- script_dir

if (!file.exists(file.path(app_dir, "app.R"))) {
  message("cchud: could not find app.R at ", file.path(app_dir, "app.R"))
  message("run.R and app.R are expected to live in the same folder.")
  quit(status = 1, save = "no")
}

# --- dependency check (scales is used via scales::hue_pal in app.R) --------
need    <- c("shiny", "ggplot2", "jsonlite", "scales")
missing <- need[!vapply(need, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) {
  message("cchud needs these R packages: ", paste(missing, collapse = ", "))
  message("Install them with:")
  message('  install.packages(c(', paste(sprintf('"%s"', missing), collapse = ", "), "))")
  quit(status = 1, save = "no")
}

# --- find a Chromium-family browser for app-mode --------------------------
find_browser <- function() {
  on_path <- Sys.which(c(
    "google-chrome", "google-chrome-stable", "chromium", "chromium-browser",
    "brave-browser", "microsoft-edge", "vivaldi-stable"
  ))
  on_path <- on_path[nzchar(on_path)]
  if (length(on_path)) return(unname(on_path[1]))

  cand <- switch(
    Sys.info()[["sysname"]],
    Darwin = c(
      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
      "/Applications/Chromium.app/Contents/MacOS/Chromium",
      "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
      "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
      "/Applications/Vivaldi.app/Contents/MacOS/Vivaldi"
    ),
    Windows = c(
      file.path(Sys.getenv("ProgramFiles"),      "Google/Chrome/Application/chrome.exe"),
      file.path(Sys.getenv("ProgramFiles(x86)"), "Google/Chrome/Application/chrome.exe"),
      file.path(Sys.getenv("LOCALAPPDATA"),      "Google/Chrome/Application/chrome.exe"),
      file.path(Sys.getenv("ProgramFiles"),      "Microsoft/Edge/Application/msedge.exe"),
      file.path(Sys.getenv("ProgramFiles(x86)"), "Microsoft/Edge/Application/msedge.exe"),
      file.path(Sys.getenv("ProgramFiles"),      "BraveSoftware/Brave-Browser/Application/brave.exe")
    ),
    character(0)
  )
  hit <- cand[file.exists(cand)]
  if (length(hit)) normalizePath(hit[1]) else NA_character_
}

# Dedicated, persistent profile: keeps the app window separate from your main
# browser (so it never lands as a tab there) and remembers its size/position.
profile_dir <- file.path(tools::R_user_dir("cchud", "cache"), "profile")
dir.create(profile_dir, recursive = TRUE, showWarnings = FALSE)

open_window <- function(url, browser, wait) {
  udd  <- if (.Platform$OS.type == "windows") shQuote(profile_dir, type = "cmd") else profile_dir
  args <- c(paste0("--app=", url),
            paste0("--user-data-dir=", udd),
            "--no-first-run", "--no-default-browser-check")
  if (Sys.info()[["sysname"]] == "Linux") args <- c(args, "--class=cchud")
  system2(browser, args, wait = wait, stdout = FALSE, stderr = FALSE)
}

# If the app has been installed as a macOS PWA (browser menu -> Install), prefer
# launching that bundle: it carries the custom Dock icon, unlike an --app window.
mac_pwa_bundle <- function() {
  if (Sys.info()[["sysname"]] != "Darwin") return(NA_character_)
  hits <- Sys.glob(file.path(path.expand("~"), "Applications", "*Apps*",
                             "Claude Code Heads-Up Display.app"))
  if (length(hits)) hits[1] else NA_character_
}

port_open <- function(port) {
  con <- tryCatch(
    socketConnection("127.0.0.1", port, open = "r+", blocking = TRUE, timeout = 1),
    warning = function(w) NULL, error = function(e) NULL)
  if (is.null(con)) return(FALSE)
  close(con)
  TRUE
}

browser <- find_browser()
if (is.na(browser)) {
  message("cchud: no Chromium-family browser found (Chrome / Edge / Brave / Chromium).")
  message("      Falling back to your default browser (opens as a tab).")
  message("      Install Chrome/Edge/Brave to get a standalone app window.")
}

have_callr <- requireNamespace("callr", quietly = TRUE)

if (!is.na(browser) && have_callr) {
  # Clean path: server in the background, window in the foreground, kill on close.
  message("cchud: starting server on ", URL, " …  (close the window to quit)")
  srv <- callr::r_bg(
    function(dir, port) shiny::runApp(dir, port = port, host = "127.0.0.1",
                                      launch.browser = FALSE),
    args = list(dir = app_dir, port = PORT))

  ok <- FALSE
  for (i in seq_len(150)) {            # up to ~15s for the server to come up
    if (!srv$is_alive()) break
    if (port_open(PORT)) { ok <- TRUE; break }
    Sys.sleep(0.1)
  }
  if (!ok) {
    message("cchud: the Shiny server did not start. Output follows:")
    cat(srv$read_all_output(), srv$read_all_error(), sep = "\n")
    if (srv$is_alive()) srv$kill()
    quit(status = 1, save = "no")
  }

  pwa <- mac_pwa_bundle()
  open_app <- if (!is.na(pwa)) {
    message("cchud: opening installed app  ", basename(pwa), "  (custom icon)")
    function() system2("open", c("-W", pwa), wait = TRUE)  # waits until it quits
  } else {
    function() open_window(URL, browser, wait = TRUE)      # --app window (browser icon)
  }
  tryCatch(open_app(), finally = if (srv$is_alive()) srv$kill())
  message("cchud: window closed, server stopped.")
  quit(status = 0, save = "no")

} else {
  # Simple path: one process. With a browser, open app-mode async (runApp must
  # keep serving). Without callr, closing the window leaves the server running.
  if (!have_callr && !is.na(browser)) {
    message("cchud: {callr} not installed — closing the window won't stop the ",
            "server. Install it for clean quit:  install.packages(\"callr\")")
  }
  opener <- if (is.na(browser)) TRUE else function(u) open_window(u, browser, wait = FALSE)
  shiny::runApp(app_dir, port = PORT, host = "127.0.0.1", launch.browser = opener)
}
