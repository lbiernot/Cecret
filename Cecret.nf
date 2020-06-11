#!/usr/bin/env nextflow

println("Currently using the Cecret workflow for use with artic-Illumina hybrid library prep on MiSeq")
println("v.20200612")

//# nextflow run /home/eriny/sandbox/Cecret/Cecret.nf -c /home/eriny/sandbox/Cecret/config/cecret.singularity.nextflow.config
//# To be used with the ivar container staphb/ivar:1.2.2_artic20200528, this includes all artic and reference files, plus the index files already exist

// To Be Added : Some sort of contamination check like Kraken2 or Blobtools
// To Be Added : pangolin for lineage tracing

params.artic_version = 'V3'
params.year = '2020'

maxcpus = Runtime.runtime.availableProcessors()
println("The maximum number of CPUS used in this workflow is ${maxcpus}")
if ( maxcpus < 5 ) {
  medcpus = maxcpus
} else {
  medcpus = 5
}

// param that coincide with the staphb/seqyclean:1.10.09 container run with singularity
params.seqyclean_contaminant_file="/Adapters_plus_PhiX_174.fasta"

// params that coincide with the staphb/ivar:1.2.2_artic20200528 container run with singularity
// when not using the container, the reference genome will need to be indexed for use with bwa
params.primer_bed = file("/artic-ncov2019/primer_schemes/nCoV-2019/${params.artic_version}/nCoV-2019.bed")
params.reference_genome = file("/artic-ncov2019/primer_schemes/nCoV-2019/${params.artic_version}/nCoV-2019.reference.fasta")
params.gff_file = file("/reference/GCF_009858895.2_ASM985889v3_genomic.gff")
params.amplicon_bed = file("/artic-ncov2019/primer_schemes/nCoV-2019/${params.artic_version}/nCoV-2019_amplicon.bed")

// This is where the results will be
params.outdir = workflow.launchDir
params.log_directory = params.outdir + '/logs'

// this sample file contains metadata for renaming files and adding collection dates to submission files
// The columns should be file_name\tsubmission_id\tcollection_date
params.sample_file = file(params.outdir + '/covid_samples.txt' )

println("The files and directory for results is " + params.outdir)
if (params.sample_file.exists()) { println("List of COVID19 samples: " + params.sample_file) }
  else {
    println "FATAL: ${params.sample_file} could not be found!\nPlease include a file name covid_samples.txt with the sample_id\tsubmission_id\tcollection_date at ${params.outdir}"
    exit 1
    }

samples = []
params.sample_file
  .readLines()
  .each { samples << it.split('\t')[0] }

Channel
  .fromFilePairs(["${params.outdir}/Sequencing_reads/Raw/*_R{1,2}_001.fastq.gz", "${params.outdir}/Sequencing_reads/Raw/*_{1,2}.fastq" ], size: 2 )
  .map{ reads -> [reads[0].replaceAll(~/_S[0-9]+_L[0-9]+/,""), reads[1]] }
  .ifEmpty{ exit 1, println("No paired fastq or fastq.gz files were found at ${params.outdir}/Sequencing_reads/Raw") }
  .into { fastq_reads; fastq_reads2; fastq_reads3; fastq_reads4 }

process seqyclean {
  publishDir "${params.outdir}", mode: 'copy'
  tag "${sample}"
  echo true
  cpus 1

  beforeScript 'mkdir -p Sequencing_reads/QCed logs/seqyclean'

  input:
  set val(sample), file(reads) from fastq_reads

  when:
  for(int i =0; i < samples.size(); i++) {
    if(sample.contains(samples[i])) { return true }
  }

  output:
  tuple sample, file("Sequencing_reads/QCed/${sample}_clean_PE{1,2}.fastq") into clean_reads, clean_reads2
  file("Sequencing_reads/QCed/${sample}_clean_SE.fastq")
  file("Sequencing_reads/QCed/${sample}_clean_SummaryStatistics.{txt,tsv}")
  file("logs/seqyclean/${sample}.${workflow.sessionId}.{log,err}")

  shell:
  '''
    log_file=logs/seqyclean/!{sample}.!{workflow.sessionId}.log
    err_file=logs/seqyclean/!{sample}.!{workflow.sessionId}.err

    # time stamp + capturing tool versions
    date | tee -a $log_file $err_file > /dev/null
    echo "seqyclean version: $(seqyclean -h | grep Version)" >> $log_file

    seqyclean -minlen 25 -qual -c !{params.seqyclean_contaminant_file} -1 !{reads[0]} -2 !{reads[1]} -o Sequencing_reads/QCed/!{sample}_clean 2>> $err_file >> $log_file
  '''
}

process bwa {
  publishDir "${params.outdir}", mode: 'copy'
  tag "${sample}"
  echo true
  cpus maxcpus

  beforeScript 'mkdir -p covid/bwa logs/bwa_covid'

  input:
  set val(sample), file(reads) from clean_reads

  output:
  tuple sample, file("covid/bwa/${sample}.sorted.bam") into bams, bams2, bams3
  file("covid/bwa/${sample}.sorted.bam.bai") into bais
  file("logs/bwa_covid/${sample}.${workflow.sessionId}.log")
  file("logs/bwa_covid/${sample}.${workflow.sessionId}.err")

  shell:
  '''
    log_file=logs/bwa_covid/!{sample}.!{workflow.sessionId}.log
    err_file=logs/bwa_covid/!{sample}.!{workflow.sessionId}.err

    # time stamp + capturing tool versions
    date | tee -a $log_file $err_file > /dev/null
    echo "bwa $(bwa 2>&1 | grep Version )" >> $log_file
    samtools --version >> $log_file

    # bwa mem command
    bwa mem -t !{maxcpus} !{params.reference_genome} !{reads[0]} !{reads[1]} 2>> $err_file | \
      samtools sort 2>> $err_file | \
      samtools view -F 4 -o covid/bwa/!{sample}.sorted.bam 2>> $err_file >> $log_file

    # indexing the bams
    samtools index covid/bwa/!{sample}.sorted.bam 2>> $err_file >> $log_file
  '''
}

process ivar_trim {
  publishDir "${params.outdir}", mode: 'copy'
  tag "${sample}"
  echo true
  cpus 1

  beforeScript 'mkdir -p covid/trimmed logs/ivar_trim'

  input:
  set val(sample), file(bam) from bams

  output:
  tuple sample, file("covid/trimmed/${sample}.primertrim.bam") into trimmed_bams
  file("logs/ivar_trim/${sample}.${workflow.sessionId}.{log,err}")

  shell:
  '''
    log_file=logs/ivar_trim/!{sample}.!{workflow.sessionId}.log
    err_file=logs/ivar_trim/!{sample}.!{workflow.sessionId}.err

    # time stamp + capturing tool versions
    date | tee -a $log_file $err_file > /dev/null
    ivar version >> $log_file

    # trimming the reads
    ivar trim -e -i !{bam} -b !{params.primer_bed} -p covid/trimmed/!{sample}.primertrim 2>> $err_file >> $log_file
  '''
}

process samtools_sort {
  publishDir "${params.outdir}", mode: 'copy'
  tag "${sample}"
  echo true
  cpus 1

  beforeScript 'mkdir -p covid/sorted logs/samtools_sort'

  input:
  set val(sample), file(bam) from trimmed_bams

  output:
  tuple sample, file("covid/sorted/${sample}.primertrim.sorted.bam") into sorted_bams, sorted_bams2, sorted_bams3, sorted_bams4
  file("covid/sorted/${sample}.primertrim.sorted.bam.bai") into sorted_bais
  file("logs/samtools_sort/${sample}.${workflow.sessionId}.{log,err}")

  shell:
  '''
    log_file=logs/samtools_sort/!{sample}.!{workflow.sessionId}.log
    err_file=logs/samtools_sort/!{sample}.!{workflow.sessionId}.err

    # time stamp + capturing tool versions
    date | tee -a $log_file $err_file > /dev/null
    samtools --version >> $log_file

    # sorting and indexing the trimmed bams
    samtools sort !{bam} -o covid/sorted/!{sample}.primertrim.sorted.bam 2>> $err_file >> $log_file
    samtools index covid/sorted/!{sample}.primertrim.sorted.bam 2>> $err_file >> $log_file
  '''
}

process ivar_variants {
  publishDir "${params.outdir}", mode: 'copy'
  tag "${sample}"
  echo true
  cpus 1

  beforeScript 'mkdir -p covid/variants logs/ivar_variants'

  input:
  set val(sample), file(bam) from sorted_bams

  output:
  file("covid/variants/${sample}.variants.tsv")
  file("logs/ivar_variants/${sample}.${workflow.sessionId}.{log,err}")

  shell:
  '''
    log_file=logs/ivar_variants/!{sample}.!{workflow.sessionId}.log
    err_file=logs/ivar_variants/!{sample}.!{workflow.sessionId}.err

    # time stamp + capturing tool versions
    date | tee -a $log_file $err_file > /dev/null
    samtools --version >> $log_file
    ivar version >> $log_file

    samtools mpileup -A -d 600000 -B -Q 0 --reference !{params.reference_genome} !{bam} 2>> $err_file | \
      ivar variants -p covid/variants/!{sample}.variants -q 20 -t 0.6 -r !{params.reference_genome} -g !{params.gff_file} 2>> $err_file >> $log_file
  '''
}

process ivar_consensus {
  publishDir "${params.outdir}", mode: 'copy'
  tag "${sample}"
  echo true
  cpus 1

  beforeScript 'mkdir -p covid/consensus logs/ivar_consensus'

  input:
  set val(sample), file(bam) from sorted_bams2

  output:
  tuple sample, file("covid/consensus/${sample}.consensus.fa") into consensus
  file("logs/ivar_consensus/${sample}.${workflow.sessionId}.{log,err}")
  tuple sample, env(degenerate), env(num_of_N) into degenerate_check, num_of_N

  shell:
  '''
    log_file=logs/ivar_consensus/!{sample}.!{workflow.sessionId}.log
    err_file=logs/ivar_consensus/!{sample}.!{workflow.sessionId}.err

    date | tee -a $log_file $err_file > /dev/null
    samtools --version >> $log_file
    ivar version >> $log_file


    samtools mpileup -A -d 6000000 -B -Q 0 --reference !{params.reference_genome} !{bam} 2>> $err_file | \
      ivar consensus -t 0.6 -p covid/consensus/!{sample}.consensus -n N 2>> $err_file >> $log_file

    degenerate=$(grep -o -E "B|D|E|F|H|I|J|K|L|M|O|P|Q|R|S|U|V|W|X|Y|Z" covid/consensus/!{sample}.consensus.fa | grep -v ">" | wc -l )
    if [ -z "$degenerate" ] ; then degenerate="0" ; fi

    num_of_N=$(grep -o 'N' covid/consensus/!{sample}.consensus.fa | grep -v ">" | wc -l )
    if [ -z "$num_of_N" ] ; then num_of_N="0" ; fi
  '''
}

fastq_reads2
  .combine(clean_reads2, by: 0)
  .set { raw_clean_reads }

process fastqc {
  publishDir "${params.outdir}", mode: 'copy'
  tag "$sample"
  echo true
  cpus 1

  beforeScript 'mkdir -p fastqc logs/fastqc'

  input:
  set val(sample), file(raw), file(clean) from raw_clean_reads

  output:
  path("fastqc/")
  tuple sample, env(raw_1), env(raw_2), env(clean_1), env(clean_2) into fastqc_results
  file("logs/fastqc/${sample}.${workflow.sessionId}.{log,err}")

  shell:
  '''
    log_file=logs/fastqc/!{sample}.!{workflow.sessionId}.log
    err_file=logs/fastqc/!{sample}.!{workflow.sessionId}.err

    # time stamp + capturing tool versions
    date | tee -a $log_file $err_file > /dev/null
    fastqc --version >> $log_file

    fastqc --outdir fastqc --threads !{task.cpus} !{sample}*.fastq* 2>> $err_file >> $log_file

    raw_1=$(unzip -p fastqc/!{raw[0].simpleName}*fastqc.zip */fastqc_data.txt | grep "Total Sequences" | awk '{ print $3 }' )
    raw_2=$(unzip -p fastqc/!{raw[1].simpleName}*fastqc.zip */fastqc_data.txt | grep "Total Sequences" | awk '{ print $3 }' )
    clean_1=$(unzip -p fastqc/!{clean[0].simpleName}*fastqc.zip */fastqc_data.txt | grep "Total Sequences" | awk '{ print $3 }' )
    clean_2=$(unzip -p fastqc/!{clean[1].simpleName}*fastqc.zip */fastqc_data.txt | grep "Total Sequences" | awk '{ print $3 }' )
  '''
}

bams3
  .combine(sorted_bams3, by: 0)
  .into { combined_bams; combined_bams2 }

process samtools_stats {
  publishDir "${params.outdir}", mode: 'copy'
  tag "${sample}"
  echo true
  cpus 1

  beforeScript 'mkdir -p covid/samtools_stats/bwa covid/samtools_stats/sort logs/samtools_stats'

  input:
  set val(sample), file(bam), file(sorted_bam) from combined_bams

  output:
  file("covid/samtools_stats/bwa/${sample}.stats.txt")
  file("covid/samtools_stats/sort/${sample}.stats.trim.txt")
  file("logs/samtools_stats/${sample}.${workflow.sessionId}.{log,err}")

  shell:
  '''
    log_file=logs/samtools_stats/!{sample}.!{workflow.sessionId}.log
    err_file=logs/samtools_stats/!{sample}.!{workflow.sessionId}.err

    date | tee -a $log_file $err_file > /dev/null
    samtools --version >> $log_file

    samtools stats !{bam} > covid/samtools_stats/bwa/!{sample}.stats.txt 2>> $err_file
    samtools stats !{sorted_bam} > covid/samtools_stats/sort/!{sample}.stats.trim.txt 2>> $err_file
  '''
}


process samtools_coverage {
  publishDir "${params.outdir}", mode: 'copy'
  tag "${sample}"
  echo true
  cpus 1

  beforeScript 'mkdir -p covid/samtools_coverage/bwa covid/samtools_coverage/sort logs/samtools_coverage'

  input:
  set val(sample), file(bwa), file(sorted) from combined_bams2

  output:
  file("covid/samtools_coverage/bwa/${sample}.cov.{txt,hist}")
  file("covid/samtools_coverage/sort/${sample}.cov.trim.{txt,hist}")
  file("logs/samtools_coverage/${sample}.${workflow.sessionId}.{log,err}")
  tuple sample, env(coverage), env(depth), env(coverage_trim), env(depth_trim) into samtools_coverage_results, samtools_coverage_results2

  shell:
  '''
    log_file=logs/samtools_coverage/!{sample}.!{workflow.sessionId}.log
    err_file=logs/samtools_coverage/!{sample}.!{workflow.sessionId}.err

    date | tee -a $log_file $err_file > /dev/null
    samtools --version >> $log_file


    samtools coverage !{bwa} -m -o covid/samtools_coverage/bwa/!{sample}.cov.hist 2>> $err_file >> $log_file
    samtools coverage !{bwa} -o covid/samtools_coverage/bwa/!{sample}.cov.txt 2>> $err_file >> $log_file
    samtools coverage !{sorted} -m -o covid/samtools_coverage/sort/!{sample}.cov.trim.hist 2>> $err_file >> $log_file
    samtools coverage !{sorted} -o covid/samtools_coverage/sort/!{sample}.cov.trim.txt 2>> $err_file >> $log_file

    coverage=$(cut -f 6 covid/samtools_coverage/bwa/!{sample}.cov.txt | tail -n 1)
    depth=$(cut -f 7 covid/samtools_coverage/bwa/!{sample}.cov.txt | tail -n 1)
    if [ -z "$coverage" ] ; then coverage="0" ; fi
    if [ -z "$depth" ] ; then depth="0" ; fi

    coverage_trim=$(cut -f 6 covid/samtools_coverage/sort/!{sample}.cov.trim.txt | tail -n 1)
    depth_trim=$(cut -f 7 covid/samtools_coverage/sort/!{sample}.cov.trim.txt | tail -n 1)
    if [ -z "$coverage_trim" ] ; then coverage_trim="0" ; fi
    if [ -z "$depth_trim" ] ; then depth_trim="0" ; fi
  '''
}

process bedtools {
  publishDir "${params.outdir}", mode: 'copy'
  tag "bedtools"
  echo true
  cpus 1

  beforeScript 'mkdir -p covid/bedtools logs/bedtools'

  input:
  file(bwa) from bams2.collect()
  file(sort) from sorted_bams4.collect()
  file(bai) from bais.collect()
  file(sorted_bai) from sorted_bais.collect()

  output:
  file("covid/bedtools/multicov.txt") into bedtools_results
  file("logs/bedtools/multicov.${workflow.sessionId}.{log,err}")

  shell:
  '''
    log_file=logs/bedtools/multicov.!{workflow.sessionId}.log
    err_file=logs/bedtools/multicov.!{workflow.sessionId}.err

    date | tee -a $log_file $err_file > /dev/null
    bedtools --version >> $log_file


    echo "primer" $(ls *bam) | tr ' ' '\t' > covid/bedtools/multicov.txt
    bedtools multicov -bams $(ls *bam) -bed !{params.amplicon_bed} | cut -f 4,6- 2>> $err_file >> covid/bedtools/multicov.txt
  '''
}

process ids {
  publishDir "${params.outdir}", mode: 'copy'
  tag "${sample}"
  echo true
  cpus 1

  beforeScript 'mkdir -p covid/bedtools logs/bedtools'

  input:
  set val(sample), file(reads) from fastq_reads3

  when:
  for(int i =0; i < samples.size(); i++) {
    if(sample.contains(samples[i])) { return true }
  }

  output:
  tuple val(sample), env(sample_id), env(submission_id), env(collection_date) into submission_ids

  shell:
  '''
    log_file=logs/bedtools/multicov.!{workflow.sessionId}.log
    err_file=logs/bedtools/multicov.!{workflow.sessionId}.err

    date | tee -a $log_file $err_file > /dev/null

    sample_id='NA'
    submission_id='NA'
    collection_date='NA'

    while read line
    do
      lab_accession=$(echo $line | awk '{print $1}' )
      if [[ "!{sample}" == *"$lab_accession"* ]]
      then
        sample_id=$lab_accession
        submission_id=$(echo $line | awk '{print $2}' )
        collection_date=$(echo $line | awk '{print $3}' )
      fi
    done < !{params.sample_file}
  '''
}

degenerate_check
  .combine(samtools_coverage_results, by: 0)
  .set{ results }

process summary {
  publishDir "${params.outdir}", mode: 'copy', overwrite: true
  tag "${sample}"
  echo true
  cpus 1

  beforeScript 'mkdir -p covid/summary logs/summary'

  input:
  set val(sample), val(degenerate_check), val(num_N), val(coverage), val(depth), val(cov_trim), val(depth_trim) from results
  file(multicov) from bedtools_results.collect()

  output:
  file("covid/summary/${sample}.summary.txt") into summary
  file("logs/summary/${sample}.${workflow.sessionId}.{log,err}")

  shell:
  '''
    log_file=logs/summary/!{sample}.!{workflow.sessionId}.log
    err_file=logs/summary/!{sample}.!{workflow.sessionId}.err

    date | tee -a $log_file $err_file > /dev/null

    bedtools_column=$(head -n 1 !{multicov} | tr '\t' '\n' | grep -n !{sample} | grep -v primertrim | cut -f 1 -d ":" | head -n 1 )
    amp_fail=$(cut -f $bedtools_column !{multicov} | awk '{ if ( $1 < 20 ) print $0 }' | wc -l )
    if [ -z "$amp_fail" ] ; then amp_fail=0 ; fi

    human_reads=$(grep "Homo" !{params.outdir}/blobtools/!{sample}*100.blobplot.stats.txt | cut -f 13 )
    if [ -z "$human_reads" ] ; then human_reads="none" ; fi

    echo "sample,%_Human_reads,num_degenerate,coverage,depth,failed_amplicons,num_N" > covid/summary/!{sample}.summary.txt
    echo "!{sample},$human_reads,!{degenerate_check},!{coverage},!{depth},$amp_fail,!{num_N}" >> covid/summary/!{sample}.summary.txt
  '''
}

fastq_reads4
  .combine(consensus, by: 0)
  .combine(num_of_N, by:0)
  .combine(submission_ids, by:0)
  .set{ reads_consensus }

process file_submission {
  publishDir "${params.outdir}", mode: 'copy'
  tag "$sample"
  echo true
  cpus 1

  beforeScript 'mkdir -p covid/submission_files logs/submission'

  input:
  set val(sample), file(reads), file(consensus), val(num_degenerate), val(num_n), val(sample_id), val(submission_id), val(collection_date) from reads_consensus

  when:
  for(int i =0; i < samples.size(); i++) {
    if(sample.contains(samples[i])) { return true }
  }

  output:
  file("covid/submission_files/${submission_id}.{R1,R2}.fastq.gz")
  file("covid/submission_files/${submission_id}.consensus.fa")
  file("covid/submission_files/${submission_id}.{genbank,gisaid}.fa") optional true into submission_complete
  file("logs/submission/${sample}.${workflow.sessionId}.{log,err}")

  shell:
  '''
  log_file=logs/submission/!{sample}.!{workflow.sessionId}.log
  err_file=logs/submission/!{sample}.!{workflow.sessionId}.err

  date | tee -a $log_file $err_file > /dev/null

  # getting the consensus fasta file
  # changing the fasta header
  echo ">!{submission_id}" > covid/submission_files/!{submission_id}.consensus.fa 2>> $err_file
  grep -v ">" !{consensus} >> covid/submission_files/!{submission_id}.consensus.fa 2>> $err_file

  if [ "!{num_n}" -lt 14952 ]
  then
    # removing leading Ns, folding sequencing to 75 bp wide, and adding metadata for genbank submissions
    echo ">!{submission_id} [organism=Severe acute respiratory syndrome coronavirus 2][isolate=SARS-CoV-2/Human/USA/!{submission_id}/!{params.year}][host=Human][country=USA][collection_date=!{collection_date}" > covid/submission_files/!{submission_id}.genbank.fa  2>> $err_file
    grep -v ">" !{consensus} | sed 's/^N*N//g' | fold -w 75 >> covid/submission_files/!{submission_id}.genbank.fa  2>> $err_file
    if [ "!{num_n}" -lt 4903 ]
    then
      cp covid/submission_files/!{submission_id}.consensus.fa covid/submission_files/!{submission_id}.gisaid.fa  2>> $err_file
      #//cat covid/submission_files/!{submission_id}.consensus.fa | sed "s/^>/>hCoV-19/USA//g" | awk '{ if ($0 ~ ">") print $0 "/2020" ; else print $0}' >> covid/submission_files/!{submission_id}.gisaid.fa  2>> $err_file
      echo "!{sample} had !{num_n} Ns and is part of the genbank and gisaid submission fasta" >> $log_file
    else
      echo "!{sample} had !{num_n} Ns and is part of the genbank submission fasta, but not gisaid" >> $log_file
    fi
  else
    echo "!{sample} had !{num_n} Ns and is not part of the genbank or the gisaid submission fasta" >> $log_file
  fi

  # copying fastq files and changing the file name
  cp !{reads[0]} covid/submission_files/!{submission_id}.R1.fastq.gz  2>> $err_file
  cp !{reads[1]} covid/submission_files/!{submission_id}.R2.fastq.gz  2>> $err_file
  '''
}

fastqc_results
  .combine(samtools_coverage_results2, by: 0)
//  .combine(pangolin, by: 0)
//  .combine(kraken2, by: 0)
  .set { all_results }

process run_results {
  publishDir "${params.outdir}", mode: 'copy', overwrite: true
  tag "${sample}"
  echo true
  cpus 1

  beforeScript 'mkdir -p covid/summary logs/run_results'

  input:
  set val(sample), val(raw_1), val(raw_2), val(clean_1), val(clean_2), val(coverage_before_trimming), val(depth_before_trimming), val(coverage_after_trimming), val(depth_after_trimming) from all_results

  output:
  file("covid/summary/${sample}.run_results.txt") into run_result
  file("logs/run_results/run_results.${workflow.sessionId}.{log,err}")

  shell:
  '''
    log_file=logs/run_results/run_results.!{workflow.sessionId}.log
    err_file=logs/run_results/run_results.!{workflow.sessionId}.err

    date | tee -a $log_file $err_file > /dev/null

    sample_id=$(echo !{sample} | cut -f 1 -d "-" )

    echo -e "sample_id\tsample\tspecies\tpangolin_lineage\tpangolin_aLRT\tpangolin_stats\tdepth_before_trimming\tdepth_after_trimming\tcoverage_before_trimming\tcoverage_after_trimming\tfastqc_raw_reads_1\tfastqc_raw_reads_2\tfastqc_clean_reads_PE1\tfastqc_clean_reads_PE2\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\t%_human_reads\t%_SARS-COV-2_reads" > covid/summary/!{sample}.run_results.txt
    echo -e "$sample_id\t!{sample}\tSARS-COV-2\tpangolin_lineage\tpangolin_aLRT\tpangolin_stats\t!{depth_before_trimming}\t!{depth_after_trimming}\t!{coverage_before_trimming}\t!{coverage_after_trimming}\t!{raw_1}\t!{raw_2}\t!{clean_1}\t!{clean_2}\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\t%_human_reads\t%_SARS-COV-2_reads" >> covid/summary/!{sample}.run_results.txt
  '''
}

process final_summary {
  publishDir "${params.outdir}", mode: 'copy', overwrite: true
  tag "summary"
  echo true
  cpus 1

  beforeScript 'mkdir -p covid/submission_files logs/summary'

  input:
  file(summary) from summary.collect()
  file(submission) from submission_complete.collect()
  file(run_result) from run_result.collect()

  output:
  file("covid/summary.txt")
  file("covid/submission_files/*.{gisaid_submission,genbank_submission}.fasta")
  file("run_results.txt")
  file("logs/summary/summary.${workflow.sessionId}.{log,err}")

  shell:
  '''
    log_file=logs/summary/summary.!{workflow.sessionId}.log
    err_file=logs/summary/summary.!{workflow.sessionId}.err

    date | tee -a $log_file $err_file > /dev/null

    echo "sample,%_Human_reads,num_degenerate,coverage,depth,failed_amplicons,num_N" > covid/summary.txt 2>> $err_file
    grep -v "failed_amplicons" *summary.txt | sort | uniq >> covid/summary.txt 2>> $err_file

    run_id=$(echo "!{params.outdir}" | rev | cut -f 1 -d '/' | rev )
    run_id=${run_id: -6}
    cat *gisaid.fa > covid/submission_files/$run_id.gisaid_submission.fasta 2>> $err_file
    cat *genbank.fa > covid/submission_files/$run_id.genbank_submission.fasta 2>> $err_file

    echo -e "sample_id\tsample\tspecies\tpangolin_lineage\tpangolin_aLRT\tpangolin_stats\tdepth_before_trimming\tdepth_after_trimming\tcoverage_before_trimming\tcoverage_after_trimming\tfastqc_raw_reads_1\tfastqc_raw_reads_2\tfastqc_clean_reads_PE1\tfastqc_clean_reads_PE2\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\t%_human_reads\t%_SARS-COV-2_reads" > run_results.txt
    grep -v "depth_after_trimming" *run_results.txt | cut -f 2 -d ":" | sort | uniq >> run_results.txt 2>> $err_file
  '''
}

workflow.onComplete {
    println("Pipeline completed at: $workflow.complete")
    println("Execution status: ${ workflow.success ? 'OK' : 'failed' }")
}
