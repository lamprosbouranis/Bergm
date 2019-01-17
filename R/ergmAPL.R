#' Adjustment of ERGM pseudolikelihood
#'
#' Function to estimate the transformation parameters for
#' adjusting the pseudolikelihood function.
#' 
#' @param formula formula; an \code{\link[ergm]{ergm}} formula object,
#' of the form  <network> ~ <model terms>
#' where <network> is a \code{\link[network]{network}} object
#' and <model terms> are \code{ergm-terms}.
#' 
#' @param aux.iters count; number of auxiliary iterations used for drawing the first network from the ERGM likelihood. See \code{\link[ergm]{control.simulate.formula}}.
#' 
#' @param n.aux.draws count; Number of auxiliary networks drawn from the ERGM likelihood. See \code{\link[ergm]{control.simulate.formula}}.
#' 
#' @param aux.thin count; Number of auxiliary iterations between network draws after the first network is drawn. See \code{\link[ergm]{control.simulate.formula}}.
#' 
#' @param ladder count; Length of temperature ladder (>=3).
#' 
#' @param ... Additional arguments, to be passed to the ergm function. See \code{\link[ergm]{ergm}}.
#'
#' @references
#' Bouranis, L., Friel, N., & Maire, F. (2018). Bayesian model selection for exponential 
#' random graph models via adjusted pseudolikelihoods. 
#' Journal of Computational and Graphical Statistics, 27(3), 516-528. \url{https://arxiv.org/abs/1706.06344}
#'
#' @export
#'
ergmAPL <- function(formula,
                    aux.iters   = NULL,
                    n.aux.draws = NULL,  
                    aux.thin    = NULL,  
                    ladder      = NULL,  
                    ...){

  y     <- ergm.getnetwork(formula)
  model <- ergm_model(formula, y)
  n     <- dim(y[,])[1]
  sy    <- summary(formula)
  dim   <- length(sy)
  
  if (dim == 1) stop("Model dimension must be greater than 1")

  if (is.null(aux.iters))   aux.iters   <- 3000
  if (is.null(n.aux.draws)) n.aux.draws <- 50  
  if (is.null(aux.thin))    aux.thin    <- 50  
  if (is.null(ladder))      ladder      <- 50  
  
  # For network simulation
  Clist   <- ergm.Cprepare(y, model)
  
  control <- control.ergm(MCMC.burnin        = aux.iters,
                          MCMC.interval      = aux.thin,
                          MCMC.samplesize    = n.aux.draws, 
                          MCMC.init.maxedges = 20000,
                          MCMC.max.maxedges  = Inf)
  
  proposal <- ergm_proposal(object      = ~., 
                            constraints = ~., 
                            arguments   = control$MCMC.prop.args, 
                            nw          = y)
  
  # SUB-ROUTINES
  
  adjusted_logPL <- function(theta,
                             Y,
                             X,
                             weights,
                             calibr.info){
    
    theta_transf <- c(calibr.info$W %*% (theta - calibr.info$Theta_MLE) + calibr.info$Theta_PL) 
    xtheta       <- c(X %*% theta_transf)
    log.like     <- sum(dbinom(weights * Y, weights, exp(xtheta) / (1 + exp(xtheta)), log = TRUE))
    return(log.like)
  }
  
  # Hessian of log pseudolikelihood:
  Hessian_logPL <- function(theta,          
                            X,
                            weights){
    
    p <- exp(as.matrix(X) %*% theta) / (1 + exp(as.matrix(X) %*% theta))
    W <- Diagonal(x = as.vector( weights * p * (1 - p))) 
    Hessian <- -t( as.matrix(X) ) %*% W %*% as.matrix(X)
    Hessian <- as.matrix(Hessian)
    return(Hessian) 
  }
  
  # Get data in aggregated format:
  mplesetup <- ergmMPLE(formula)
  data.glm.initial <- cbind(mplesetup$response, 
                            mplesetup$weights, 
                            mplesetup$predictor)
  colnames(data.glm.initial) <- c("responses", 
                                  "weights", 
                                  colnames(mplesetup$predictor))

  path <- seq(0, 1, length.out = ladder)
  
  suppressMessages(mle  <- ergm(formula, estimate = "MLE",  verbose = FALSE, ...) )
  suppressMessages(mple <- ergm(formula, estimate = "MPLE", verbose = FALSE) )

  # Simulate from the MLE:
  delta <- ergm_MCMC_slave(Clist    = Clist,
                           proposal = proposal,
                           eta      = mle$coef,
                           control  = control,
                           verbose  = FALSE)$s

  sim.samples <- sweep(delta, 2, sy, '+')
  
  # Hessian of true log-posterior: 
  Hessian.true.logLL <- -cov(sim.samples)
  
  HPL <- Hessian_logPL(theta   = mple$coef,          
                       X       = mplesetup$predictor,
                       weights = mplesetup$weights)
  
  chol.true.Hessian <- chol(-Hessian.true.logLL)
  chol.PL.Hessian   <- chol(-HPL)
  
  # Calculate transformation matrix W:
  W <- solve(chol.PL.Hessian) %*% chol.true.Hessian

  adjust.info <- list(Theta_MLE = mle$coef,
                      Theta_PL  = mple$coef,
                      W = W)
  
  E <- lapply(seq_along(path)[-length(path)], function(i){
                 delta <- ergm_MCMC_slave(Clist    = Clist,
                                          proposal = proposal,
                                          eta      = path[i]*adjust.info$Theta_MLE,
                                          control  = control,
                                          verbose  = FALSE)$s
                 
                 Monte.Carlo.samples <- sweep(delta, 2, sy, '+')
                 log(mean(exp((path[i + 1] - path[i]) * adjust.info$Theta_MLE %*% t(Monte.Carlo.samples))))
                 }
              )
  
  E <- sum(unlist(E))
  
  # Estimate log z(0) depending on the type of network:
  if (y$gal$directed == FALSE) logz0 <- choose(n, 2) * log(2) else logz0 <- (n * (n - 1)) * log(2)
  logztheta <- E + logz0
               
  #
  ll.true <- c(matrix(adjust.info$Theta_MLE, nrow = 1) %*% sy) - logztheta
  
  ll.adjpseudo <-  adjusted_logPL(theta       = adjust.info$Theta_MLE,
                                  Y           = mplesetup$response,
                                  X           = mplesetup$predictor,
                                  weights     = mplesetup$weights,
                                  calibr.info = adjust.info)  
  
  out <- list(formula      = formula,
              Theta_MLE    = mle$coef,
              Theta_PL     = mple$coef,
              W            = W,
              C            = exp(ll.true - ll.adjpseudo),
              ll_true      = ll.true,
              logztheta    = logztheta,
              ll_adjpseudo = ll.adjpseudo)

  return(out)
}