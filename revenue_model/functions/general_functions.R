
# try exponential back off when sending data to S3 to avoid throttling
# from https://rdrr.io/github/ramhiser/retry/src/R/try-backoff.r
try_backoff <- function(expr, silent=FALSE, max_attempts=10, verbose=FALSE) {
  for (attempt_i in seq_len(max_attempts)) {
    results <- try(expr=expr, silent=silent)
    if (class(results) == "try-error") {
      backoff <- runif(n=1, min=0, max=2^attempt_i - 1)
      if (verbose) {
        message("Backing off for ", backoff, " seconds.")
      }
      Sys.sleep(backoff)
    } else {
      if (verbose) {
        message("Succeeded after ", attempt_i, " attempts.")
      }
      break
    }
  }
  results
}