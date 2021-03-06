#' Generate Mplus code for Thurstonian IRT models
#'
#' @inheritParams fit_TIRT_stan
#' @param eta_file optional file name in which predicted
#'   trait scores should be stored.
#' @param iter Maximum number of iterations of the
#'   model fitting algorithm.
#'
#' @return A list of Mplus code snippets to be
#' interpreted by the \pkg{MplusAutomation} package.
#'
#' @examples
#' sdata <- sim_TIRT_data(
#'   npersons = 100,
#'   ntraits = 3,
#'   nblocks_per_trait = 4,
#'   gamma = 0,
#'   lambda = c(runif(6, 0.5, 1), runif(6, -1, -0.5)),
#'   Phi = diag(3)
#' )
#' lapply(make_mplus_code(sdata), cat)
#'
#' @export
make_mplus_code <- function(data, iter = 1000,
                            eta_file = "eta.csv") {
  # TODO: make better interface to Mplus' control parameters
  if (!is.TIRTdata(data)) {
    stop("'data' should be of class 'TIRTdata'. See ?make_TIRT_data")
  }
  iter <- round(as_one_numeric(iter))
  data <- convert_factors(data)
  data <- filter(data, .data$person == unique(.data$person)[1])
  att <- attributes(data)
  family <- check_family(att$family, "mplus")
  nitems <- att[["nitems"]]
  nitems_per_block <- att[["nitems_per_block"]]
  ntraits <- att[["ntraits"]]
  traits <- seq_len(ntraits)
  if (isTRUE(att[["partial"]])) {
    stop("Cannot yet handle partial comparisons when using Mplus.")
  }

  # define factor loadings (lambda)
  mplus_loadings <- vector("list", ntraits)
  for (i in traits) {
    for (n in seq_len(nrow(data))) {
      if (data$trait1[n] == i) {
        mplus_loadings[[i]] <- c(mplus_loadings[[i]], with(data,
           paste0("i", item1[n], "i", item2[n], "*1  (L", item1[n], ")")
        ))
      } else if (data$trait2[n] == i) {
        mplus_loadings[[i]] <- c(mplus_loadings[[i]], with(data,
           paste0("i", item1[n], "i", item2[n], "*-1  (L", item2[n], "n)")
        ))
      }
    }
    mplus_loadings[[i]] <- paste0(
      "trait", i, " BY\n",
      paste0(mplus_loadings[[i]], collapse = "\n"),
      ";\n"
    )
  }
  mplus_loadings <- collapse(unlist(mplus_loadings), "\n")

  # fix factor varianaces to 1
  mplus_fix_factor_variances <- collapse("trait", traits, "@1\n")

  # factor correlations
  mplus_factor_correlations <- collapse(
    sapply(1:(ntraits - 1),
      function(i) paste0(
        "trait", i, " WITH ",
        paste0("trait", (i+1):ntraits, "*0", collapse = " "),
        ";\n"
      )
    )
  )

  # fix factor loadings of the same item to the same value
  items_both_dir <- which(
    1:nitems %in% data$item1 & 1:nitems %in% data$item2
  )
  mplus_fix_factor_loadings <- collapse(
    "L", items_both_dir, " = -L", items_both_dir, "n;\n"
  )

  # declare uniquenesses (psi)
  mplus_uniqueness <- with(data, collapse(
    "i", item1, "i", item2, "*1 (P", item1, "P", item2, ");\n"
  ))

  # correlated uniqunesses
  mplus_cor_uniqueness <- ""
  for (n in 1:(nrow(data) - 1)) {
    for (m in (n+1):nrow(data)) {
      pos_psi1 <- with(data, item1[n] == item1[m])
      pos_psi2 <- with(data, item2[n] == item2[m])
      neg_psi <- with(data, item2[n] == item1[m])
      if (pos_psi1) {
        mplus_cor_uniqueness <- with(data,
          paste0(mplus_cor_uniqueness,
            "i", item1[n], "i", item2[n], " WITH ",
            "i", item1[m], "i", item2[m], "*1 ",
            "(P", item1[n], ");\n"
          )
        )
      } else if (pos_psi2) {
        mplus_cor_uniqueness <- with(data,
          paste0(mplus_cor_uniqueness,
            "i", item1[n], "i", item2[n], " WITH ",
            "i", item1[m], "i", item2[m], "*1 ",
            "(P", item2[n], ");\n"
          )
        )
      } else if (neg_psi) {
        mplus_cor_uniqueness <- with(data,
          paste0(mplus_cor_uniqueness,
            "i", item1[n], "i", item2[n], " WITH ",
            "i", item1[m], "i", item2[m], "*-1 ",
            "(P", item2[n], "n);\n"
          )
        )
      }
    }
  }

  # pair's uniqueness is equal to sum of 2 utility uniqunesses
  psi_item1 <- paste0("P", data$item1)
  psi_item2 <- paste0("P", data$item2)
  neg_psi1 <- sapply(
    paste0(" \\(", psi_item1, "n\\);"),
    grepl, mplus_cor_uniqueness
  )
  neg_psi2 <- sapply(
    paste0(" \\(", psi_item2, "n\\);"),
    grepl, mplus_cor_uniqueness
  )
  mplus_equal_uniqueness <- with(data, collapse(
    psi_item1, psi_item2, " = ",
    ifelse(neg_psi1, paste0("- ", psi_item1, "n"), psi_item1),
    ifelse(neg_psi2, paste0("- ", psi_item2, "n"), paste0(" + ", psi_item2)),
    ";\n"
  ))

  # fix one uniqueness per block for identification
  mplus_fix_uniqueness <- collapse(
    "P", seq(1, nitems, nitems_per_block), " = 1;\n"
  )

  # force item parameters of the same item to be equal
  # this happens if the same items is applied in multiple blocks
  mplus_equal_items <- ""
  for (i in seq_along(att$dupl_items)) {
    first <- att$dupl_items[[i]][1]
    dup <- att$dupl_items[[i]][-1]
    mplus_equal_items <- paste0(mplus_equal_items,
      collapse("L", first, " = L", dup, ";\n"),
      collapse("P", first, " = P", dup, ";\n")
    )
  }

  # combine all mplus code snippets into a list
  list(
    TITLE = "Thurstonian IRT model",
    DATA = collapse_lines(
      "! It is assumed that the input file contains only item responses",
      "! Any additional variables should be added below"
    ),
    VARIABLE = collapse_lines(
      "CATEGORICAL ARE ALL;\n"
    ),
    ANALYSIS = collapse_lines(
      "  ESTIMATOR = ulsmv;",
      paste0("  ITERATIONS = ", iter, ";"),
      "  PARAMETERIZATION = theta;\n"
    ),
    MODEL = collapse_lines(
      "! factor loadings (lambda)",
      mplus_loadings,
      "! fix factor variances to 1",
      mplus_fix_factor_variances,
      "! factor correlations",
      mplus_factor_correlations,
      "! declare uniquenesses (psi)",
      mplus_uniqueness,
      "! correlated uniqunesses",
      mplus_cor_uniqueness
    ),
    MODELCONSTRAINT = collapse_lines(
      "! fix factor loadings of the same item to the same value",
      mplus_fix_factor_loadings,
      "! pair's uniqueness is equal to sum of 2 utility uniqunesses",
      mplus_equal_uniqueness,
      "! fix one uniqueness per block for identification",
      mplus_fix_uniqueness,
      "! force item parameters of the same item to be equal",
      mplus_equal_items,
      "! trait scores for individuals are estimated and saved in a file"
    ),
    SAVEDATA = collapse_lines(
      paste0("  FILE IS '", eta_file, "';"),
      "  SAVE = FSCORES;"
    )
  )
}

#' Fit Thurstonian IRT models in Mplus
#'
#' @inheritParams fit_TIRT_stan
#' @param ... Further arguments passed to
#'   \code{\link[MplusAutomation:mplusModeler]{mplusModeler}}.
#'
#' @return A \code{'TIRTfit'} object.
#'
#' @export
fit_TIRT_mplus <- function(data, ...) {
  file_name <- collapse(sample(0:9, 10, TRUE))
  mplus_data <- make_sem_data(data)
  mplus_model <- make_mplus_code(
    data, eta_file = paste0(file_name, ".csv"), ...
  )
  mplus_object <- suppressMessages(
    do.call(
      MplusAutomation::mplusObject,
      c(mplus_model, list(rdata = mplus_data))
    )
  )
  inp_file <- paste0(file_name, ".inp")
  out_file <- paste0(file_name, ".out")
  fit <- MplusAutomation::mplusModeler(
    mplus_object, modelout = inp_file,
    run = 1L, writeData = "always"
  )
  fit$model_code <- readChar(inp_file, file.info(inp_file)$size)
  # cleanup
  unlink(inp_file)
  unlink(paste0(file_name, ".out"))
  unlink(gsub("\"", "", fit$results$input$data$file, fixed = TRUE))
  unlink(fit$results$savedata_info$fileName)
  # save only the trait scores
  npersons <- attr(data, "npersons")
  traits <- attr(data, "traits")
  trait_scores <- fit$results[["savedata"]]
  ncol_save <- ncol(trait_scores)
  if (is.numeric(ncol_save) && length(ncol_save) > 0) {
    tcols <- (ncol_save - length(traits) + 1):ncol_save
    fit$results$savedata <- trait_scores[, tcols, drop = FALSE]
  } else {
    trait_scores <- matrix(NA, ncol = length(traits), nrow = npersons)
    colnames(trait_scores) <- traits
    fit$results$savedata <- trait_scores
  }
  class(fit) <- c("mplusObjectTIRT", class(fit))
  structure(nlist(fit, data), class = "TIRTfit")
}

is.mplusObjectTIRT <- function(x) {
  inherits(x, "mplusObjectTIRT")
}

#' @export
print.mplusObjectTIRT <- function(x, digits = 2, ...) {
  cat("Model Name:", x$TITLE, "\n")
  cat("Results:\n")
  print(x$results$parameters$unstandardized, digits = digits)
  invisible(x)
}

#' @method summary mplusObjectTIRT
#' @export
summary.mplusObjectTIRT <- function(object, ...) {
  object$results$parameters$unstandardized
}
