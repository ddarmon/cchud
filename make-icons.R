#!/usr/bin/env Rscript
# Generates the cchud app icons into ./www/ using only base R graphics
# (no external SVG/raster tools). Re-run after editing to regenerate.
# Theme matches app.R: parchment background, amber gauge — a burn-rate meter.

this <- local({
  a <- commandArgs(FALSE)
  f <- sub("^--file=", "", a[grepl("^--file=", a)])
  if (length(f)) normalizePath(f[1]) else NA_character_
})
dir <- if (!is.na(this)) dirname(this) else normalizePath(getwd())
www <- file.path(dir, "www")
dir.create(www, showWarnings = FALSE, recursive = TRUE)

render <- function(path, px) {
  ok <- tryCatch({ png(path, width = px, height = px, bg = "#e8ddc7"); TRUE },
                 error = function(e) FALSE)
  if (!ok) png(path, width = px, height = px, bg = "#e8ddc7", type = "cairo")
  on.exit(dev.off())
  par(mar = c(0, 0, 0, 0), xpd = NA)
  plot.new(); plot.window(xlim = c(-1, 1), ylim = c(-1, 1), asp = 1)

  a0 <- 220 * pi / 180; a1 <- -40 * pi / 180   # 260° sweep, gap at the bottom
  r  <- 0.74
  track_lwd <- px * 0.10

  th <- seq(a0, a1, length.out = 256)
  lines(r * cos(th), r * sin(th), col = "#d8cdaf", lwd = track_lwd, lend = 1)  # track

  frac <- 0.66                                  # "value" arc
  thv  <- seq(a0, a0 + (a1 - a0) * frac, length.out = 200)
  lines(r * cos(thv), r * sin(thv), col = "#9a6a12", lwd = track_lwd, lend = 1)

  for (f in seq(0, 1, by = 0.25)) {             # ticks
    ang <- a0 + (a1 - a0) * f
    lines(c(0.55, 0.66) * cos(ang), c(0.55, 0.66) * sin(ang),
          col = "#8a7d5f", lwd = px * 0.012, lend = 1)
  }

  ang <- a0 + (a1 - a0) * frac                  # needle + hub
  lines(c(-0.06, 0.62 * cos(ang)), c(0.02, 0.62 * sin(ang)),
        col = "#8a5a1e", lwd = px * 0.028, lend = 1)
  symbols(0, 0, circles = 0.12, inches = FALSE, add = TRUE, bg = "#8a5a1e", fg = NA)

  text(0, -0.42, "$", col = "#9a6a12", cex = px / 512 * 3.2, font = 2)
  invisible(path)
}

render(file.path(www, "icon-512.png"), 512)
render(file.path(www, "icon-192.png"), 192)
render(file.path(www, "icon.png"),    1024)
cat("cchud icons written to", www, "\n")
