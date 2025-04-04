## define functions
#' Interpolate a p-value from quantiles that should be "null scaled"
#'
#' @param q bootstrap quantiles, centered so that under the null, theta = 0
#' @return two-sided p-value
#' @export
interp_pval = function(q) {
  R = length(q)
  tstar = sort(q)
  zero = findInterval(0, tstar)
  if(zero == 0 || zero == R) return(2/R) # at/beyond extreme values
  pval = 2*min(zero/R, (R-zero)/R)
  pval
}


#' Derive a p-value from a vector of bootstrap samples using the "basic" calculation
#'
#' @param obs observed value of parameter (using actual data)
#' @param boot vector of bootstraps
#'
#' @return p-value
#' @export
basic_p = function(obs, boot, null = 0){
  interp_pval(2*obs - boot - null)
}


#' Perform poisson regression: exprs ~ peak + covariates
#'
#' @param data contains expr values and associated peak and covariates for a gene.
#' @param idx rows of the data to use: argument for boot function (bootstrapping)
#' @param formula user defined formula based on initialization in CreateSCENTObj Constructor
#'
#' @return vector: (coefficient of the peak effect on gene, variance of peak effect on gene)
#' @export
assoc_poisson = function(data, idx = seq_len(nrow(data)), formula){
  gg = glm(formula, family = 'poisson', data = data[idx,,drop = FALSE])
  c(coef(gg)['atac'], diag(vcov(gg))['atac'])
}

#' Perform poisson regression using fastglm: exprs ~ peak + covariates + intercept
#'
#' @param data contains expr values and associated peak and covariates for a gene.
#' @param pred_var predictor vars
#' @param res_var result var
#' @param idx rows of the data to use: argument for boot function (bootstrapping)
#'
#' @return vector: (coefficient of the peak effect on gene, variance of peak effect on gene)
#' @export
assoc_poisson_fast =  function(data, pred_var, res_var, idx = seq_len(nrow(data))){
  X = as.matrix(data[idx, pred_var, drop = FALSE])
  model = fastglm::fastglm(X, data[idx, res_var], family = poisson())
  # vcov_matrix <- solve(t(X) %*% diag(gg$weights) %*% X)  ## too slow and causes memory issues
  W <- Matrix::Diagonal(x = model$weights)  # Sparse diagonal weight matrix
  Hessian <- t(X) %*% W %*% X  # Compute Hessian
  vcov_matrix <- solve(Hessian)  # Inverse to get variance-covariance matrix
  c(coef(model)['atac'], diag(vcov_matrix)['atac'])
}

#' Perform negative binomial regression: exprs ~ peak + covariates
#'
#' @param data contains expr values and associated peak and covariates for a gene.
#' @param idx rows of the data to use: argument for boot function (bootstrapping)
#' @param formula user defined formula based on initialization in CreateSCENTObj Constructor
#'
#' @return vector: (coefficient of the peak effect on gene, variance of peak effect on gene)
#' @export
assoc_negbin = function(data, idx = seq_len(nrow(data)), formula){
  gg = glm.nb(formula, data = data[idx,,drop = FALSE])
  c(coef(gg)['atac'], diag(vcov(gg))['atac'])
}



#' Validity and Type Checking for CreateSCENTObject Constructor
#'
#' @param object SCENT object constructed from class CreateSCENTObject
#'
#' @return None OR Errors dependent on if the object follows the guidelines for SCENT
#' RNA: matrix of (genes x cells)
#' ATAC: matrix of (peaks x cells)
#' @export
check_dimensions <- function(object){
  errors <- character()

  #Check dimensionality of cells:
  num_cells_rna <- lengths(object@rna@Dimnames)[2]
  num_cells_atac <- lengths(object@atac@Dimnames)[2]

  num_genes <- lengths(object@rna@Dimnames)[1]
  num_peaks <- lengths(object@atac@Dimnames)[1]

  #Check if the number of cells match between rna and atac matrix.
  if(num_cells_rna != num_cells_atac){
    msg <- paste("Error: The num of cells in scRNA matrix is: ", num_cells_rna,
                 " and the num of cells in scATAC matrix is: ", num_cells_atac,
                 ". These should EQUAL EACH OTHER, please check to make sure",
                 " both matrices for scRNA and scATAC are read in as",
                 " (genes x cells) and (peaks x cells), respectively. ")
    errors <- c(errors, msg)
  }


  #Most likely the number of peaks is greater than the number of genes if not WARN.
  if(num_peaks < num_genes){
    warning(paste("Warning: in general there are more peaks found through ATAC",
                   " than genes. Currently you have number of peaks =", num_peaks,
                   " and number of genes =",num_genes))
  }

  #If peak.info is present check the following:
  if(!(length(object@peak.info) == 0)){
    #Check if genes correspond between rna matrix and peak.info dataframe:
    if(!all(object@peak.info[[1]] %in% object@rna@Dimnames[[1]])){
      msg <- paste("The gene names in the peak.info dataframe is NOT a subset of the gene names in",
                   " the scRNA matrix")
      errors <- c(errors, msg)
    }


    #Check if peaks correspond between atac matrix and peak.info dataframe:
    if(!all(object@peak.info[[2]] %in% object@atac@Dimnames[[1]])){
      msg <- paste("The peak ids in the peak.info dataframe is NOT a subset of the peak names in",
                   " the scATAC matrix")
      errors <- c(errors, msg)
    }
  }


  ###Additional things to check:
  #Check if meta.data table with covariates has the correct cell column names
  #Check if covariates are in the columns of meta.data
  if (length(errors) == 0) TRUE else errors
}



#' SCENT Class Constructor
#'
#' @slot rna dgCMatrix. scRNAseq matrix read as a sparse matrix
#' @slot atac dgCMatrix. scATACseq matrix read as a sparse matrix
#' @slot meta.data data.frame. Metadata table with covariates and a cell ID column ("cell")
#' @slot peak.info data.frame. Dataframe that contains gene-peak pairs for SCENT to search through
#' @slot peak.info.list list. List of dataframes that contain gene-peak pairs to parallelize through
#' @slot covariates character. Assign covariates that are needed for the analysis. Must be names that are in the columns of meta.data
#' @slot celltypes character. Assign celltype column from meta.data
#' @slot SCENT.result data.frame. Initialized as empty. Becomes a table of resultant significant gene peak pairs
#'
#' @return SCENT object to use for further analysis
#' @exportClass SCENT
setClass(
  Class = "SCENT",
  slots = c(
    rna = 'dgCMatrix',
    atac = 'dgCMatrix',
    meta.data = 'data.frame',
    peak.info = 'data.frame',  ###Must be gene (1st column) then peak (2nd column)
    peak.info.list = 'list',
    covariates = 'character',
    celltypes = 'character',
    SCENT.result = 'data.frame'
  ),
  validity = check_dimensions
)

#' SCENT Algorithm: Poisson Regression with Empirical P-values through Bootstrapping.
#'
#' @param object SCENT object
#' @param celltype character. User specified cell type defined in celltypes column of meta.data
#' @param ncores numeric. Number of cores to use for Parallelization
#' @param regr character. Regression type: "poisson" or "negbin" for Poisson regression and Negative Binomial regression, respectively
#' @param bin logical. TRUE to binarize ATAC counts. FALSE to NOT binarize ATAC counts
#'
#' @return SCENT object with updated field SCENT.results
#' @export
SCENT_algorithm <- function(object, celltype, ncores, regr = "poisson", bin = TRUE){
  res <- data.frame()
  print("starting")
  for (n in 1:nrow(object@peak.info)){ ####c(1:nrow(chunkinfo))
    gene <- object@peak.info[n,1] #GENE is FIRST COLUMN OF PEAK.INFO
    this_peak <- object@peak.info[n,2] #PEAK is SECOND COLUMN OF PEAK.INFO
    atac_target <- data.frame(cell = colnames(object@atac), atac = object@atac[this_peak,])


    #binarize peaks:
    if(bin){
      if(nrow(atac_target[atac_target$atac>0,])>0){
        atac_target[atac_target$atac>0,]$atac<-1
      }
    }

    mrna_target <- object@rna[gene,]
    df <- data.frame(cell=names(mrna_target),exprs=as.numeric(mrna_target))
    df<-merge(df,atac_target,by="cell")
    df<-merge(df,object@meta.data,by="cell")

    df2 <- df[df[[object@celltypes]] == celltype,]

    nonzero_m  <- length( df2$exprs[ df2$exprs > 0] ) / length( df2$exprs )
    nonzero_a  <- length( df2$atac[ df2$atac > 0] ) / length( df2$atac )
    if(nonzero_m > 0.05 & nonzero_a > 0.05){
      #Run Regression Once Before Bootstrapping:
      res_var <- "exprs"
      pred_var <- c("atac", object@covariates)
      formula <- as.formula(paste(res_var, paste(pred_var, collapse = "+"), sep = "~"))


      #Estimated Coefficients Obtained without Bootstrapping:
      if(regr == "poisson"){
        base = glm(formula, family = 'poisson', data = df2)
        coefs<-summary(base)$coefficients["atac",]
        assoc <- assoc_poisson
      } else if (regr == "negbin"){
        base = glm.nb(formula, data = df2)
        coefs<-summary(base)$coefficients["atac",]
        assoc <- assoc_negbin
      }

      ###Iterative Bootstrapping Procedure: Estimate the Beta coefficients and associate a 2-sided p-value.
      bs = boot::boot(df2,assoc, R = 100, formula = formula, stype = 'i', parallel = "multicore", ncpus = ncores)
      p0 = basic_p(bs$t0[1], bs$t[,1])
      if(p0<0.1){
        bs = boot::boot(df2,assoc, R = 500, formula = formula,  stype = 'i', parallel = "multicore", ncpus = ncores)
        p0 = basic_p(bs$t0[1], bs$t[,1])
      }
      if(p0<0.05){
        bs = boot::boot(df2,assoc, R = 2500, formula = formula,  stype = 'i', parallel = "multicore", ncpus = ncores)
        p0 = basic_p(bs$t0[1], bs$t[,1])
      }
      if(p0<0.01){
        bs = boot::boot(df2,assoc, R = 25000, formula = formula,  stype = 'i', parallel = "multicore", ncpus = ncores)
        p0 = basic_p(bs$t0[1], bs$t[,1])
      }
      if(p0<0.001){
        bs = boot::boot(df2,assoc, R = 50000, formula = formula, stype = 'i', parallel = "multicore", ncpus = ncores)
        p0 = basic_p(bs$t0[1], bs$t[,1])
      }
      out <- data.frame(gene=gene,peak=this_peak,beta=coefs[1],se=coefs[2],z=coefs[3],p=coefs[4],boot_basic_p=p0)
      res<-rbind(res,out)
    } else {
      print("sparse skip")
    }
  }

  #Update the SCENT.result field of the constructor in R:
  object@SCENT.result <- res
  return(object)
}



#' SCENT Algorithm: Poisson Regression with Empirical P-values through Bootstrapping.
#' Changes relative to the SCENT_algorithm function include: fastglm instead of glm (note need to explicitly add intercept in fastglm),
#' R bootstrap sampling based on initial p value, not sequential.
#' Also, use lapply instead of for loop.
#' @param object SCENT object
#' @param celltype character. User specified cell type defined in celltypes column of meta.data
#' @param ncores numeric. Number of cores to use for Parallelization
#' @param regr character. Regression type: "poisson" or "negbin" for Poisson regression and Negative Binomial regression, respectively
#' @param bin logical. TRUE to binarize ATAC counts. FALSE to NOT binarize ATAC counts
#' @param output_file character. name of output file. If provided, results are appended to this file as and when generated.
#' @param samplingseq character. The sequence of R samplings. Default is what the orginial SCENT_algorithm function had. Custom has lower number of R samplings for a faster run.
#'
#' @return SCENT object with updated field SCENT.results
#' @export
SCENT_algorithm_fast <- function(object, celltype, ncores, regr = "poisson", bin = TRUE, output_file = NULL, samplingseq = "default"){
  res <- data.frame()
  print("starting")
  res <- as.data.frame(do.call(rbind, lapply(1:nrow(object@peak.info), function(n){ ####c(1:nrow(chunkinfo))
    gene <- object@peak.info[n,1] #GENE is FIRST COLUMN OF PEAK.INFO
    this_peak <- object@peak.info[n,2] #PEAK is SECOND COLUMN OF PEAK.INFO
    atac_target <- data.frame(cell = colnames(object@atac), atac = object@atac[this_peak,])


    #binarize peaks:
    if(bin){
      if(nrow(atac_target[atac_target$atac>0,])>0){
        atac_target[atac_target$atac>0,]$atac<-1
      }
    }

    mrna_target <- object@rna[gene,]
    df <- data.frame(cell=names(mrna_target),exprs=as.numeric(mrna_target))
    df<-merge(df,atac_target,by="cell")
    df<-merge(df,object@meta.data,by="cell")

    df2 <- df[df[[object@celltypes]] == celltype,]
    df2$intercept = 1

    nonzero_m  <- length( df2$exprs[ df2$exprs > 0] ) / length( df2$exprs )
    nonzero_a  <- length( df2$atac[ df2$atac > 0] ) / length( df2$atac )
    if(nonzero_m > 0.05 & nonzero_a > 0.05){
      #Run Regression Once Before Bootstrapping:
      res_var <- "exprs"
      pred_var <- c("atac", object@covariates, "intercept")


      #Estimated Coefficients Obtained without Bootstrapping:
      if(regr == "poisson"){
        base = fastglm(as.matrix(df2[, pred_var]), df2$exprs, family = poisson())
        coefs<-summary(base)$coefficients["atac",]
        assoc <- assoc_poisson_fast
      } else if (regr == "negbin"){
        base = glm.nb(formula, data = df2)
        coefs<-summary(base)$coefficients["atac",]
        assoc <- assoc_negbin
      }

      ###Iterative Bootstrapping Procedure: Estimate the Beta coefficients and associate a 2-sided p-value.
      R = 100
      bs = boot::boot(df2, assoc, R = R, pred_var=pred_var, res_var=res_var, stype = 'i', parallel = "multicore", ncpus = ncores)
      p0 = basic_p(bs$t0[1], bs$t[,1])
      p00 = p0
      if (samplingseq == "default"){### sequence of p val ranges and R samplings in the original function
        if(p0<0.1){
          R = 500
          bs = boot::boot(df2, assoc, R = R, pred_var=pred_var, res_var=res_var, stype = 'i', parallel = "multicore", ncpus = ncores)
          p0 = basic_p(bs$t0[1], bs$t[,1])
        }
        if(p0<0.05){
          R = 2500
          bs = boot::boot(df2, assoc, R = R, pred_var=pred_var, res_var=res_var,  stype = 'i', parallel = "multicore", ncpus = ncores)
          p0 = basic_p(bs$t0[1], bs$t[,1])
        }
        if(p0<0.01){
          R = 25000
          bs = boot::boot(df2, assoc, R = R, pred_var=pred_var, res_var=res_var,  stype = 'i', parallel = "multicore", ncpus = ncores)
          p0 = basic_p(bs$t0[1], bs$t[,1])
        }
        if(p0<0.001){
          R = 50000
          bs = boot::boot(df2, assoc, R = R, pred_var=pred_var, res_var=res_var, stype = 'i', parallel = "multicore", ncpus = ncores)
          p0 = basic_p(bs$t0[1], bs$t[,1])
        }
      } else if (samplingseq == "custom"){
        if(p0>=0.05 & p0<0.1){
          R = 500
          bs = boot::boot(df2, assoc, R = R, pred_var=pred_var, res_var=res_var, stype = 'i', parallel = "multicore", ncpus = ncores)
          p0 = basic_p(bs$t0[1], bs$t[,1])
        } else if(p0>=0.01 & p0<0.05){
          R = 2500
          bs = boot::boot(df2, assoc, R = R, pred_var=pred_var, res_var=res_var,  stype = 'i', parallel = "multicore", ncpus = ncores)
          p0 = basic_p(bs$t0[1], bs$t[,1])
        }
        ## if p value becomes more significant after 500 or 2500 samplings, do more samplings.
        if(p0>=0.001 & p0<0.01){
          R = 5000
          bs = boot::boot(df2, assoc, R = R, pred_var=pred_var, res_var=res_var,  stype = 'i', parallel = "multicore", ncpus = ncores)
          p0 = basic_p(bs$t0[1], bs$t[,1])
        } else if(p0<0.001){
          R = 10000
          bs = boot::boot(df2, assoc, R = R, pred_var=pred_var, res_var=res_var, stype = 'i', parallel = "multicore", ncpus = ncores)
          p0 = basic_p(bs$t0[1], bs$t[,1])
        }
      }
      out <- data.frame(gene=gene,peak=this_peak,beta=coefs[1],se=coefs[2],z=coefs[3],p=coefs[4],p_100_boots=p00,R=R,boot_basic_p=p0)
    } else {
      out <- data.frame(gene=gene,peak=this_peak,beta=NA,se=NA,z=NA,p=NA,p_100_boots=NA,boot_basic_p=NA,R=NA)
      print(glue("{gene} - {this_peak} sparse skip"))
    }
    if (!is.null(output_file)){
      write.table(out, file = output_file, append = TRUE, col.names = !file.exists(output_file), row.names = FALSE, sep = "\t", quote=F)
    }
    return(out)
  })))

  #Update the SCENT.result field of the constructor in R:
  object@SCENT.result <- res
  return(object)
}

#' Creating Cis Gene-Peak Pair Lists to Parallelize Through
#'
#' @param object SCENT object
#' @param genebed character. File directory for bed file that contains 500 kb windows for each gene
#' @param nbatch numeric. Number of batches to produce: Length of the list
#' @param tmpfile character. Location of temporary file.
#' @param intersectedfile character. Location of intersected file.
#'
#' @return SCENT object with updated field of peak.info.list
#' @export
CreatePeakToGeneList <- function(object,genebed="/path/to/GeneBody_500kb_margin.bed",nbatch,tmpfile="./temporary_atac_peak.bed",intersectedfile="./temporary_atac_peak_intersected.bed.gz"){
  peaknames <- rownames(object@atac) # peak by cell matrix
  peaknames_r <- gsub(":","-",peaknames) # in case separator included ":"
  peaknames_r <- gsub("_","-",peaknames_r) # in case separator included "_"
  peak_bed <- data.frame(chr = str_split_fixed(peaknames_r,"-",3)[,1], start = str_split_fixed(peaknames_r,"-",3)[,2], end = str_split_fixed(peaknames_r,"-",3)[,3], peak=peaknames)
  write.table(peak_bed,tmpfile,quote=F,row=F,col=F,sep="\t")
  system(paste("bedtools intersect -a",genebed,"-b ",tmpfile, " -wa -wb -loj | gzip -c >", intersectedfile))
  system(paste("rm ", tmpfile))
  d <- fread(intersectedfile,sep="\t")
  d<-data.frame(d)
  d <- d[d$V5 != ".",]

  #Obtain gene to peak pairs.
  cis.g2p <- d[c("V4","V8")]
  colnames(cis.g2p) <- c("gene","peak")
  genes_in_rna <- rownames(object@rna) # gene by cell matrix
  cis.g2p <- cis.g2p[cis.g2p$gene %in% genes_in_rna,] # make sure g2p genes are all included in rna matrix

  cis.g2p$index <- 1:nrow(cis.g2p)
  cis.g2p$batch_index <- cut2(cis.g2p$index, g = nbatch, levels.mean = TRUE)
  cis.g2p_list <- split(cis.g2p, f = cis.g2p$batch_index)
  cis.g2p_list <- lapply(cis.g2p_list, function(x) x[(names(x) %in% c("peak", "gene"))])
  names(cis.g2p_list) <- 1:length(cis.g2p_list)
  # Update the SCENT.peak.info field of the constructor in R:
  object@peak.info.list <- cis.g2p_list
  return(object)
}




