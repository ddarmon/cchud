# statusline HUD — a live heads-up display for the cost/burn-rate metering
# that statusline.sh persists to ~/.claude/.cost-cache/<session_id>.tsv
#
# The statusline writes, per session, an atomic file:
#   line 1 : <last-change-ts>\t<cost-at-change>     (survives window pruning)
#   line 2+: <ts>\t<cost>                            (snapshots inside the window)
# and reports Δcost/Δt over the last CACHE_WINDOW seconds, flipping to "idle"
# once cost has been flat for IDLE_AFTER seconds. This app re-implements that
# exact math (the awk END block in statusline.sh) and renders it live.
#
# Run:  Rscript -e 'shiny::runApp("app.R", port=4747, launch.browser=TRUE)'

library(shiny)
library(ggplot2)
library(jsonlite)

# --- constants, mirrored from statusline.sh ---------------------------------
CACHE_DIR    <- path.expand("~/.claude/.cost-cache")
PROJECTS_DIR <- path.expand("~/.claude/projects")
CACHE_WINDOW <- 300   # 5-min look-back for the recent burn rate
IDLE_AFTER   <- 120   # cost flat this many secs -> idle
REFRESH_MS   <- 2000  # HUD tick: re-read + recompute against wall clock
HOME         <- path.expand("~")

# --- pricing, from LiteLLM's public model-price file (the same source ccusage
# uses): per-token input/output + cache-read/-creation costs for ~2.8k models.
# Fetched once and cached to disk, so we neither hand-maintain a table nor hit
# the network on every 2s tick. The 1h cache-write tier isn't a LiteLLM field,
# so it falls back to Anthropic's 2x-input rule (matching the old hand math).
PRICING_URL     <- "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
PRICING_CACHE   <- file.path(CACHE_DIR, ".litellm_pricing.json")
PRICING_TTL     <- 86400        # refresh the on-disk snapshot at most once a day
WEB_SEARCH_COST <- 10 / 1000    # Anthropic web search: $10 per 1,000 requests

`%||%` <- function(a, b)
  if (is.null(a) || length(a) == 0 || (length(a) == 1 && is.na(a))) b else a

.pricing_env <- new.env(parent = emptyenv())

# The whole LiteLLM table, loaded once per process. Refresh the disk snapshot if
# it's missing or stale; if the fetch fails, fall back to whatever is cached.
load_pricing <- function() {
  if (!is.null(.pricing_env$tbl)) return(.pricing_env$tbl)
  fresh <- file.exists(PRICING_CACHE) &&
    (as.numeric(Sys.time()) - as.numeric(file.info(PRICING_CACHE)$mtime)) < PRICING_TTL
  if (!fresh) {
    tryCatch(
      utils::download.file(PRICING_URL, PRICING_CACHE, quiet = TRUE, mode = "wb"),
      error = function(e) NULL, warning = function(e) NULL)
  }
  tbl <- if (file.exists(PRICING_CACHE))
    tryCatch(jsonlite::fromJSON(PRICING_CACHE, simplifyVector = FALSE),
             error = function(e) list())
  else list()
  .pricing_env$tbl <- tbl
  tbl
}

# LiteLLM keys models bare ("claude-opus-4-8") or vendor-prefixed; try both.
model_pricing <- function(model) {
  tbl <- load_pricing()
  tbl[[model]] %||% tbl[[paste0("anthropic/", model)]]
}

# Cost of one assistant message in $; NA when the model has no pricing entry.
msg_cost <- function(model, u) {
  if (is.null(model) || is.na(model)) return(NA_real_)
  p <- model_pricing(model)
  if (is.null(p)) return(NA_real_)
  ci <- p$input_cost_per_token; co <- p$output_cost_per_token
  if (is.null(ci) || is.null(co)) return(NA_real_)
  cr  <- p$cache_read_input_token_cost     %||% (0.10 * ci)   # cache read = 0.1x in
  cw  <- p$cache_creation_input_token_cost %||% (1.25 * ci)   # 5m write   = 1.25x in
  c1h <- 2.0 * ci                                             # 1h write   = 2x in (not in LiteLLM)
  u$input * ci + u$output * co +
    u$cread * cr + u$c5m * cw + u$c1h * c1h +
    u$websearch * WEB_SEARCH_COST
}

# --- transcript enrichment (real on-disk data the statusline never shows) ---
# A session's transcript lives at projects/<encoded-cwd>/<session_id>.jsonl and
# carries the working dir + per-message token usage. Both are cached so the 2s
# HUD tick stays cheap: cwd never changes; tokens re-scan only when the file grows.
.cwd_cache <- new.env(parent = emptyenv())
.tok_cache <- new.env(parent = emptyenv())

find_transcript <- function(id) {
  hits <- Sys.glob(file.path(PROJECTS_DIR, "*", paste0(id, ".jsonl")))
  if (length(hits)) hits[[1]] else NA_character_
}

session_cwd <- function(id, transcript) {
  cached <- .cwd_cache[[id]]
  if (!is.null(cached) && !is.na(cached)) return(cached)
  cwd <- NA_character_
  if (!is.na(transcript)) {
    ls <- tryCatch(readLines(transcript, n = 60, warn = FALSE), error = function(e) character(0))
    for (l in ls) {
      rec <- tryCatch(jsonlite::fromJSON(l, simplifyVector = FALSE), error = function(e) NULL)
      c <- if (is.null(rec)) NULL else rec$cwd
      if (!is.null(c) && nzchar(c)) { cwd <- sub(HOME, "~", c, fixed = TRUE); break }
    }
  }
  .cwd_cache[[id]] <- cwd
  cwd
}

# Parse a transcript into deduped token totals + a full-session cumulative-cost
# series (the permanent "trip log" the 5-min .tsv odometer can't provide).
# jsonlite reads each record's real structure, so the nested iterations[] usage
# block can't be mistaken for a second top-level count the way regex once did.
session_history <- function(transcript) {
  if (is.na(transcript) || !file.exists(transcript)) return(NULL)
  mt <- as.numeric(file.info(transcript)$mtime)
  c0 <- .tok_cache[[transcript]]
  if (!is.null(c0) && isTRUE(c0$mtime == mt)) return(c0$hist)

  ls <- tryCatch(readLines(transcript, warn = FALSE), error = function(e) character(0))
  ls <- ls[grepl('"usage"', ls, fixed = TRUE) & grepl('"type":"assistant"', ls, fixed = TRUE)]

  tot <- list(input = 0, output = 0, cread = 0, ccreate = 0)
  rows <- vector("list", length(ls)); unpriced <- character(0); cum <- 0; n <- 0
  seen <- new.env(parent = emptyenv())   # O(1) dedup, not an O(n^2) %in% scan
  for (l in ls) {
    rec <- tryCatch(jsonlite::fromJSON(l, simplifyVector = FALSE), error = function(e) NULL)
    if (is.null(rec)) next
    msg <- rec$message; usg <- msg$usage
    if (is.null(usg)) next

    # Each assistant message is logged ~2x (streaming + sidechain re-emission);
    # count each id once or every token (and dollar) comes out ~2.2x high.
    id <- msg$id
    if (!is.null(id)) { if (!is.null(seen[[id]])) next; seen[[id]] <- TRUE }

    cc <- usg$cache_creation; st <- usg$server_tool_use
    u <- list(
      input     = usg$input_tokens                %||% 0,
      output    = usg$output_tokens               %||% 0,
      cread     = usg$cache_read_input_tokens     %||% 0,
      c5m       = cc$ephemeral_5m_input_tokens    %||% 0,
      c1h       = cc$ephemeral_1h_input_tokens    %||% 0,
      websearch = st$web_search_requests          %||% 0
    )
    tot$input   <- tot$input   + u$input
    tot$output  <- tot$output  + u$output
    tot$cread   <- tot$cread   + u$cread
    tot$ccreate <- tot$ccreate + u$c5m + u$c1h

    model <- msg$model %||% NA_character_
    cost  <- msg_cost(model, u)
    if (is.na(cost)) { unpriced <- union(unpriced, if (is.na(model)) "unknown" else model); next }

    ts <- as.numeric(as.POSIXct(rec$timestamp,
                                format = "%Y-%m-%dT%H:%M:%OS", tz = "UTC"))
    if (is.na(ts)) next
    cum <- cum + cost; n <- n + 1
    rows[[n]] <- data.frame(ts = ts, cum = cum)
  }
  tot$total <- tot$input + tot$output + tot$cread + tot$ccreate

  hist <- list(
    tok        = tot,
    cost_df    = if (n > 0) do.call(rbind, rows[seq_len(n)]) else NULL,
    cost_total = if (n > 0) cum else NA_real_,
    unpriced   = unpriced
  )
  .tok_cache[[transcript]] <- list(mtime = mt, hist = hist)
  hist
}

# Read one session .tsv into a list mirroring statusline's per-session state.
read_session <- function(path, now, window = CACHE_WINDOW) {
  lines <- tryCatch(readLines(path, warn = FALSE), error = function(e) character(0))
  if (length(lines) == 0) return(NULL)

  hdr <- strsplit(lines[1], "\t", fixed = TRUE)[[1]]
  lc_ts   <- suppressWarnings(as.numeric(hdr[1]))
  lc_cost <- suppressWarnings(as.numeric(hdr[2]))
  if (is.na(lc_ts) || is.na(lc_cost)) return(NULL)

  snaps <- data.frame(ts = numeric(0), cost = numeric(0))
  if (length(lines) > 1) {
    sp <- do.call(rbind, lapply(strsplit(lines[-1], "\t", fixed = TRUE), function(x) {
      as.numeric(x[1:2])
    }))
    sp <- sp[stats::complete.cases(sp), , drop = FALSE]
    if (nrow(sp) > 0) snaps <- data.frame(ts = sp[, 1], cost = sp[, 2])
  }

  # Current cost = the last-change cost (line 1); guard with snapshot max.
  cur_cost <- max(lc_cost, if (nrow(snaps)) max(snaps$cost) else lc_cost)

  # Windowed burn rate, exactly as statusline's awk END block.
  win <- snaps[snaps$ts >= now - window, , drop = FALSE]
  rate <- NA_real_; win_delta <- NA_real_
  if (nrow(win) > 0) {
    o_ts   <- win$ts[which.min(win$ts)]
    o_cost <- win$cost[which.min(win$ts)]
    span   <- now - o_ts
    win_delta <- cur_cost - o_cost                # $ spent inside the window
    if (span >= 60 && cur_cost > o_cost) rate <- (cur_cost - o_cost) * 3600 / span
    # NB: the api-duration fallback rate is NOT on disk (it lives only in the
    # live stdin payload), so flat sessions simply report no rate here.
  }

  idle <- (now - lc_ts) > IDLE_AFTER

  list(
    id        = sub("\\.tsv$", "", basename(path)),
    cur_cost  = cur_cost,
    rate      = rate,
    win_delta = win_delta,
    idle      = idle,
    last_age  = now - lc_ts,           # secs since cost last changed
    n_snaps   = nrow(snaps),
    fresh     = (now - as.numeric(file.info(path)$mtime)) < 3600,  # render fired in last hr
    snaps     = snaps
  )
}

load_all <- function(window = CACHE_WINDOW) {
  now <- as.numeric(Sys.time())
  files <- list.files(CACHE_DIR, pattern = "\\.tsv$", full.names = TRUE)
  sessions <- Filter(Negate(is.null), lapply(files, read_session, now = now, window = window))
  sessions <- lapply(sessions, function(x) {
    tr <- find_transcript(x$id)
    x$cwd <- session_cwd(x$id, tr)
    h <- session_history(tr)
    x$tok        <- if (is.null(h)) NULL else h$tok
    x$cost_df    <- if (is.null(h)) NULL else h$cost_df
    x$cost_total <- if (is.null(h)) NA_real_ else h$cost_total
    x$unpriced   <- if (is.null(h)) character(0) else h$unpriced
    x
  })
  list(now = now, sessions = sessions, window = window)
}

fmt_age <- function(s) {
  s <- max(0, round(s))
  if (s < 60)    sprintf("%ds", s)
  else if (s < 3600) sprintf("%dm%02ds", s %/% 60, s %% 60)
  else sprintf("%dh%02dm", s %/% 3600, (s %% 3600) %/% 60)
}

fmt_tok <- function(n) {
  if (is.null(n) || is.na(n)) return("—")
  if (n >= 1e6) sprintf("%.1fM", n / 1e6)
  else if (n >= 1e3) sprintf("%.0fk", n / 1e3)
  else as.character(round(n))
}

short_dir <- function(p) {  # keep last 2 path segments for a tidy column
  if (is.null(p) || is.na(p)) return("—")
  segs <- strsplit(p, "/", fixed = TRUE)[[1]]
  segs <- segs[nzchar(segs)]
  if (length(segs) <= 2) p else paste0(".../", paste(tail(segs, 2), collapse = "/"))
}

hud_theme <- function() {  # shared parchment palette for both trajectory plots
  theme_minimal(base_size = 13) +
    theme(
      plot.background  = element_rect(fill = "#e8ddc7", color = NA),
      panel.background = element_rect(fill = "#f3ecda", color = NA),
      panel.grid       = element_line(color = "#d8cdaf"),
      text = element_text(color = "#3a3326"),
      plot.subtitle = element_text(color = "#9a6a12", size = 12, face = "bold"),
      axis.text = element_text(color = "#8a7d5f"),
      legend.position = "bottom"
    )
}

# --- UI ---------------------------------------------------------------------
ui <- fluidPage(
  tags$head(
    tags$title("Claude Code Heads-Up Display"),
    tags$link(rel = "manifest", href = "manifest.webmanifest"),
    tags$link(rel = "icon", type = "image/png", href = "icon-192.png"),
    tags$link(rel = "apple-touch-icon", href = "icon-192.png"),
    tags$meta(name = "theme-color", content = "#e8ddc7"),
    tags$meta(name = "apple-mobile-web-app-capable", content = "yes"),
    tags$meta(name = "apple-mobile-web-app-title", content = "cchud"),
    tags$style(HTML("
    body { background:#e8ddc7; color:#3a3326; font-family:'SF Mono',Menlo,monospace; }
    .hud-title { font-size:15px; letter-spacing:2px; color:#8a5a1e; text-transform:uppercase; }
    .stat-row { display:flex; gap:14px; margin:14px 0 20px; flex-wrap:wrap; }
    .stat { background:#f3ecda; border:1px solid #cbbf9f; border-radius:8px;
            padding:12px 18px; min-width:130px; }
    .stat .lbl { font-size:11px; color:#8a7d5f; text-transform:uppercase; letter-spacing:1px; }
    .stat .val { font-size:26px; font-weight:600; margin-top:4px; }
    .v-cost { color:#9a6a12; } .v-rate { color:#4a7c2f; } .v-act { color:#2f6ea5; }
    .v-idle { color:#8a7d5f; } .v-tok { color:#7a5ba0; }
    table { width:100%; border-collapse:collapse; font-size:13px; }
    th { text-align:left; color:#8a7d5f; border-bottom:1px solid #cbbf9f; padding:6px 10px;
         text-transform:uppercase; font-size:11px; letter-spacing:1px; }
    td { padding:6px 10px; border-bottom:1px solid #ddd2b8; }
    .pill { padding:1px 8px; border-radius:10px; font-size:11px; }
    .pill-active { background:#d6e4c2; color:#3f6b22; }
    .pill-idle   { background:#e0d6bd; color:#8a7d5f; }
  "))),
  div(class = "hud-title", "◢ Claude Code Heads-Up Display"),
  div(style = "font-size:11px;color:#8a7d5f;", textOutput("clock", inline = TRUE)),
  uiOutput("stats"),
  tags$h4("Sessions", style = "color:#8a7d5f;font-size:12px;letter-spacing:1px;"),
  tableOutput("sessions"),
  fluidRow(
    column(6,
      uiOutput("traj_title"),
      # spacer matching the look-back control's height, so the two plots align
      div(style = "height:34px;margin:0 0 12px;"),
      plotOutput("trajectory", height = "300px")),
    column(6,
      tags$h4("Full-session cost trajectory (whole life, from transcripts)",
              style = "color:#8a7d5f;font-size:12px;letter-spacing:1px;margin-top:24px;"),
      div(style = "margin:0 0 12px;",
        tags$label("Look-back (hr)",
                   style = "font-size:11px;color:#8a7d5f;text-transform:uppercase;letter-spacing:1px;margin-right:10px;"),
        div(style = "display:inline-block;width:90px;vertical-align:middle;",
            numericInput("life_lookback", label = NULL, value = NA,
                         min = 0.5, step = 0.5)),
        tags$span("blank = whole session",
                  style = "font-size:11px;color:#8a7d5f;margin-left:10px;")),
      plotOutput("lifetime", height = "300px"))
  )
)

# --- server -----------------------------------------------------------------
server <- function(input, output, session) {
  state <- reactive({
    invalidateLater(REFRESH_MS, session)
    load_all(window = CACHE_WINDOW)
  })

  # One id -> color map shared by both trajectory plots, so a given session is
  # the same hue everywhere. Keyed on the sorted set of all current sessions, so
  # the assignment only shifts when sessions appear/disappear (not every tick).
  session_colors <- reactive({
    ids <- sort(unique(vapply(state()$sessions, function(x) substr(x$id, 1, 8), "")))
    setNames(scales::hue_pal()(length(ids)), ids)
  })

  output$clock <- renderText({
    s <- state()
    sprintf("updated %s  ·  %d cached session(s)  ·  refresh %ds",
            format(Sys.time(), "%H:%M:%S"), length(s$sessions), REFRESH_MS / 1000)
  })

  output$stats <- renderUI({
    s <- state(); ss <- s$sessions
    active <- Filter(function(x) !x$idle, ss)
    total_cost  <- sum(vapply(ss, function(x) x$cur_cost, 0))
    active_cost <- sum(vapply(active, function(x) x$cur_cost, 0))
    burn <- sum(vapply(active, function(x) if (is.na(x$rate)) 0 else x$rate, 0))
    toks <- sum(vapply(ss, function(x) if (is.null(x$tok)) 0 else x$tok$total, 0))

    stat <- function(lbl, val, cls)
      div(class = "stat", div(class = "lbl", lbl), div(class = paste("val", cls), val))

    div(class = "stat-row",
      stat("active", length(active), "v-act"),
      stat("idle / total", sprintf("%d / %d", length(ss) - length(active), length(ss)), "v-idle"),
      stat("active cost", sprintf("$%.2f", active_cost), "v-cost"),
      stat("all cached cost", sprintf("$%.2f", total_cost), "v-cost"),
      stat("combined burn", sprintf("$%.1f/h", burn), "v-rate"),
      stat("tokens (cached)", fmt_tok(toks), "v-tok")
    )
  })

  output$sessions <- renderTable({
    ss <- state()$sessions
    if (length(ss) == 0) return(data.frame(note = "no cached sessions"))
    ss <- ss[order(vapply(ss, function(x) x$last_age, 0))]
    data.frame(
      session = vapply(ss, function(x) substr(x$id, 1, 8), ""),
      dir     = vapply(ss, function(x) short_dir(x$cwd), ""),
      status  = vapply(ss, function(x) if (x$idle) "idle" else "active", ""),
      cost    = vapply(ss, function(x) sprintf("$%.2f", x$cur_cost), ""),
      `burn $/h` = vapply(ss, function(x) if (is.na(x$rate)) "—"
                          else if (x$rate >= 10) sprintf("%.0f", x$rate)
                          else sprintf("%.1f", x$rate), ""),
      `5m Δ$`  = vapply(ss, function(x) if (is.na(x$win_delta) || x$win_delta <= 0) "—"
                        else sprintf("$%.2f", x$win_delta), ""),
      tokens  = vapply(ss, function(x) if (is.null(x$tok)) "—" else fmt_tok(x$tok$total), ""),
      `last change` = vapply(ss, function(x) fmt_age(x$last_age), ""),
      snaps = vapply(ss, function(x) as.integer(x$n_snaps), 0L),
      check.names = FALSE, stringsAsFactors = FALSE
    )
  }, sanitize.text.function = identity)

  output$traj_title <- renderUI({
    mins <- round(state()$window / 60)
    tags$h4(sprintf("Cost trajectory (active sessions, last %d min)", mins),
            style = "color:#8a7d5f;font-size:12px;letter-spacing:1px;margin-top:24px;")
  })

  output$trajectory <- renderPlot({
    s <- state()
    act <- Filter(function(x) !x$idle && nrow(x$snaps) > 1, s$sessions)
    if (length(act) == 0) {
      return(ggplot() + annotate("text", 0, 0, label = "no active sessions with a moving cost",
                                 color = "#8a7d5f", size = 5) +
               theme_void() + theme(plot.background = element_rect(fill = "#e8ddc7", color = NA)))
    }
    df <- do.call(rbind, lapply(act, function(x) {
      d <- x$snaps; d$session <- substr(x$id, 1, 8)
      d$rel <- (d$ts - s$now) / 60   # minutes relative to now (negative = past)
      d
    }))
    ggplot(df, aes(rel, cost, color = session)) +
      geom_step(linewidth = 0.9) + geom_point(size = 1.6) +
      labs(x = "minutes ago", y = "session cost ($)", color = NULL) +
      scale_color_manual(values = session_colors()) +
      scale_y_continuous(limits = c(0, NA), expand = expansion(mult = c(0, 0.05))) +
      # Clip the VIEW to the window (coord), don't DROP rows (scale limits) —
      # the latter deletes pre-window snapshots and severs the step line at the
      # left edge, and is what was emitting the "Removed N rows" warnings.
      coord_cartesian(xlim = c(-s$window / 60, 0)) +
      hud_theme()
  })

  # Long-term "trip log": cumulative cost over each session's entire life,
  # reconstructed from the never-pruned transcript .jsonl (not the 5-min .tsv).
  output$lifetime <- renderPlot({
    s <- state(); ss <- s$sessions
    unpriced <- unique(unlist(lapply(ss, function(x) x$unpriced)))
    have <- Filter(function(x) !is.null(x$cost_df) && nrow(x$cost_df) > 1, ss)

    if (length(have) == 0) {
      msg <- if (length(unpriced))
        paste0("no priced cost history — model(s) missing pricing: ",
               paste(unpriced, collapse = ", "))
      else "no transcript cost history yet"
      return(ggplot() + annotate("text", 0, 0, label = msg, color = "#8a7d5f", size = 5) +
               theme_void() + theme(plot.background = element_rect(fill = "#e8ddc7", color = NA)))
    }

    df <- do.call(rbind, lapply(have, function(x) {
      d <- x$cost_df; d$session <- substr(x$id, 1, 8)
      d$hr <- (d$ts - s$now) / 3600     # hours relative to now (negative = past)
      d
    }))

    # Whole-life total: each session's final cumulative cost, summed.
    total_spend <- sum(vapply(split(df$cum, df$session), max, 0))

    # Optional shorter look-back (in hours) just for this whole-life plot.
    lb <- input$life_lookback
    windowed <- !is.null(lb) && !is.na(lb) && lb > 0
    if (windowed) {
      # Spend inside the window = final cum minus the cumulative cost at the
      # window's left edge. We carry that baseline from the last snapshot
      # strictly before the window (0 if the session began inside it), so the
      # figure is exact rather than approximated by the first retained row.
      window_spend <- sum(vapply(split(df, df$session), function(d) {
        pre  <- d$cum[d$hr < -lb]
        base <- if (length(pre)) max(pre) else 0
        max(d$cum) - base
      }, 0))
      df <- df[df$hr >= -lb, , drop = FALSE]
    }

    subtitle <- if (windowed)
      sprintf("window: $%.2f  ·  total: $%.2f", window_spend, total_spend)
    else
      sprintf("total: $%.2f", total_spend)

    ggplot(df, aes(hr, cum, color = session)) +
      geom_step(linewidth = 0.9) + geom_point(size = 1) +
      labs(x = "hours ago", y = "cumulative cost ($)", color = NULL,
           subtitle = subtitle,
           caption = if (length(unpriced))
             paste0("excluded — no pricing for: ", paste(unpriced, collapse = ", ")) else NULL) +
      scale_color_manual(values = session_colors()) +
      scale_y_continuous(limits = c(0, NA), expand = expansion(mult = c(0, 0.05))) +
      hud_theme()
  })
}

shinyApp(ui, server)
