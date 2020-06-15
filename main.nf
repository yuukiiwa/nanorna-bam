#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/nanornabam
========================================================================================
 nf-core/nanornabam Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/nanornabam
----------------------------------------------------------------------------------------
*/


def helpMessage() {
    // TODO nf-core: Add to this help message with new command line parameters
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/nanornabam -input samples.csv -profile docker

    Mandatory arguments:
      --input                       Comma-separated file containing information about the samples in the experiment (see docs/usage.md)
      -profile                      Configuration profile to use. Can use multiple (comma separated)
                                    Available: conda, docker, singularity, awsbatch, test and more.

    Other options:
      --outdir                      The output directory where the results will be saved
      --email                       Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --maxMultiqcEmailFileSize     Theshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name                         Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.
      --help                        Generates the help page

    AWSBatch options:
      --awsqueue                    The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion                   The AWS Region for your AWS Batch job to run on
    """.stripIndent()
}

/*
 * SET UP CONFIGURATION VARIABLES
 */
// Show help message
if (params.help){
    helpMessage()
    exit 0
}

if (params.input) { ch_input = file(params.input, checkIfExists: true) } else { exit 1, "Samplesheet file not specified!" }
ch_transcriptquant = params.transcriptquant

// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if( !(workflow.runName ==~ /[a-z]+_[a-z]+/) ){
  custom_runName = workflow.runName
}


if( workflow.profile == 'awsbatch') {
  // AWSBatch sanity checking
  if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
  // Check outdir paths to be S3 buckets if running on AWSBatch
  // related: https://github.com/nextflow-io/nextflow/issues/813
  if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
  // Prevent trace files to be stored on S3 since S3 does not support rolling files.
  if (workflow.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Stage config files
ch_multiqc_config = Channel.fromPath(params.multiqc_config)
ch_output_docs = Channel.fromPath("$baseDir/docs/output.md")


// Header log info
log.info nfcoreHeader()
def summary = [:]
if(workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
// TODO nf-core: Report custom parameters here
summary['Samplesheet']      = params.input
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if(workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if(workflow.profile == 'awsbatch'){
   summary['AWS Region']    = params.awsregion
   summary['AWS Queue']     = params.awsqueue
}
summary['Config Profile'] = workflow.profile
if(params.config_profile_description) summary['Config Description'] = params.config_profile_description
if(params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if(params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if(params.email) {
  summary['E-mail Address']  = params.email
  summary['MultiQC maxsize'] = params.maxMultiqcEmailFileSize
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "\033[2m----------------------------------------------------\033[0m"

// Check the hostnames against configured profiles
checkHostname()

/*
 * STEP 1 - Process samplesheet
 */
process CheckSampleSheet {
    tag "$name"
    publishDir "${params.outdir}", mode: 'copy'

    input:
    file samplesheet from ch_input

    output:
    file "*reformat.csv" into ch_samplesheet_reformat
    file "*conditions.csv" into ch_sample_condition

    script:
    """
    check_samplesheet.py \\
        $samplesheet \\
        samplesheet_reformat.csv
    """
}

// Function to resolve gtf file if using iGenomes and to check the bam file exists
// Returns [ sample, bam, annotation]
def get_sample_info(LinkedHashMap sample, LinkedHashMap genomeMap) {

    // Resolve gtf file if using iGenomes
    def fasta = false
    def gtf = false
    if (sample.genome) {
        if (genomeMap.containsKey(sample.genome)) {
	    fasta = file(genomeMap[sample.genome].fa, checkIfExists: true)
            gtf = file(genomeMap[sample.genome].gtf, checkIfExists: true)
        } else {
            fasta = file(sample.genome, checkIfExists: true)
            gtf = file(sample.transcriptome, checkIfExists: true)
        }
    }

    // Check if bam file exists
    bam = file(sample.bam, checkIfExists: true)

    return [ sample.sample, bam, fasta, gtf]
}

// Sort the samplesheet entries into correct channels
ch_samplesheet_reformat
    .splitCsv(header:true, sep:',')
    .map { get_sample_info(it, params.genomes) }
    .map { it -> [ it[0], it[1], it[2], it[3] ] } // [samplename, bam, gtf, fasta]
    .into { ch_txome_reconstruction;
           ch_bambu_input}
ch_sample_condition
    .splitCsv(header:false, sep:',')
    .map {it -> it.size()}
    .into { ch_deseq2_num_condition;
            ch_dexseq_num_condition}

/*
 * STEP 2a - StringTie2 & FeatureCounts
 */
process StringTie2 {
    publishDir "${params.outdir}/stringtie2", mode: 'copy',
        saveAs: { filename ->
                      if (!filename.endsWith(".version")) filename
                }

    input:
    set val(name), file(bam), val(genomeseq), val(annot) from ch_txome_reconstruction
    val transcriptquant from ch_transcriptquant

    output:
    set val(name), file(bam) into ch_txome_feature_count
    val annot into ch_annot
    file("*.version") into ch_stringtie_version
    val "${params.outdir}/stringtie2" into ch_stringtie_outputs
    file "*.out.gtf"

    when:
    transcriptquant == "stringtie"

    script:
    """
    stringtie -L -G $annot -o ${name}.out.gtf $bam
    stringtie --version &> stringtie.version
    """
}
ch_stringtie_outputs
   .unique()
   .set {ch_stringtie_dir}
ch_annot
   .unique()
   .set{ch_annotation}

process GffCompare {
    publishDir "${params.outdir}/stringtie2", mode: 'copy',
        saveAs: { filename ->
                      if (!filename.endsWith(".version")) filename
                }
    input:
    val stringtie_dir from ch_stringtie_dir
    val annot from ch_annotation
    val transcriptquant from ch_transcriptquant

    output:
    val "$stringtie_dir/merged.combined.gtf" into ch_merged_gtf

    when:
    transcriptquant == "stringtie"

    script:
    """
    ls -d -1 $PWD/$stringtie_dir/*.out.gtf > $PWD/$stringtie_dir/gtf_list.txt
    echo "$annot" >> $PWD/$stringtie_dir/gtf_list.txt
    gffcompare -i $PWD/$stringtie_dir/gtf_list.txt -o $PWD/$stringtie_dir/merged
    gffcompare --version &> gffcompare.version
    """
}

ch_txome_feature_count
   .combine(ch_merged_gtf)
   .set {ch_feature_count}

process FeatureCounts {
     publishDir "${params.outdir}/featureCounts_transcript", mode: 'copy',
         saveAs: { filename ->
                 if (!filename.endsWith(".version")) filename
                 }

     input:
     set val(name), file(bam), val(annot) from ch_feature_count
     val transcriptquant from ch_transcriptquant

     output:
     file("*.txt") into ch_counts
     file("*.version") into ch_feat_counts_version
     val "$baseDir/results/featureCounts_transcript" into ch_deseq2_indir
     val "$baseDir/results/featureCounts_transcript" into ch_dexseq_indir

     when:
     transcriptquant == "stringtie"

     script:
     """
     featureCounts -g transcript_id --extraAttributes gene_id  -T $task.cpus -a $PWD/$annot -o ${name}.transcript_counts.txt $bam
     featureCounts -v &> featureCounts.version
     """
 }

/*
 * STEP 2b - Bambu
 */
params.Bambuscript= "$baseDir/bin/runBambu.R"
ch_Bambuscript = Channel.fromPath("$params.Bambuscript", checkIfExists:true)

process Bambu {
  publishDir "${params.outdir}/Bambu", mode: 'copy',
        saveAs: { filename ->
                      if (!filename.endsWith(".version")) filename
                }

  input:
  set val(name), file(bam), val(genomeseq), val(annot) from ch_bambu_input
  file Bambuscript from ch_Bambuscript
  file sampleinfo from ch_input
  val transcriptquant from ch_transcriptquant

  output:
  val "$baseDir/results/Bambu/counts_gene.txt" into ch_deseq2_in
  val "$baseDir/results/Bambu/counts_transcript.txt" into ch_dexseq_in

  when:
  transcriptquant == "bambu"

  script:
  """
  Rscript --vanilla $Bambuscript $PWD $sampleinfo $PWD/results/Bambu/ $genomeseq
  """
}

if( ch_transcriptquant == "stringtie"){
  ch_deseq2_in = ch_deseq2_indir
  ch_dexseq_in = ch_dexseq_indir
}

/*
 * STEP 3 - DESeq2
 */
params.DEscript= "$baseDir/bin/runDESeq2.R"
ch_DEscript = Channel.fromPath("$params.DEscript", checkIfExists:true)

process DESeq2 {
  publishDir "${params.outdir}/DESeq2", mode: 'copy',
        saveAs: { filename ->
                      if (!filename.endsWith(".version")) filename
                }

  input:
  file sampleinfo from ch_input
  file DESeq2script from ch_DEscript
  val inpath from ch_deseq2_in
  val num_condition from ch_deseq2_num_condition
  val transcriptquant from ch_transcriptquant

  output:
  file "*.txt" into ch_DEout

  when:
  num_condition >= 2

  script:
  """
  Rscript --vanilla $DESeq2script $transcriptquant $inpath $sampleinfo 
  """
}

/*
 * STEP 4 - DEXseq
 */
params.DEXscript= "$baseDir/bin/runDEXseq.R"
ch_DEXscript = Channel.fromPath("$params.DEXscript", checkIfExists:true)

process DEXseq {
  publishDir "${params.outdir}/DEXseq", mode: 'copy',
        saveAs: { filename ->
                      if (!filename.endsWith(".version")) filename
                }

  input:
  file sampleinfo from ch_input
  file DEXscript from ch_DEXscript
  val inpath from ch_dexseq_in
  val num_condition from ch_dexseq_num_condition
  val transcriptquant from ch_transcriptquant

  output:
  file "*.txt" into ch_DEXout

  when:
  num_condition >= 2

  script:
  """
  Rscript --vanilla $DEXscript $transcriptquant $inpath $sampleinfo
  """
}

// process output_documentation {
//     publishDir "${params.outdir}/pipeline_info", mode: 'copy'
//
//     input:
//     file output_docs from ch_output_docs
//
//     output:
//     file "results_description.html"
//
//     script:
//     """
//     markdown_to_html.r $output_docs results_description.html
//     """
// }

/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy',
        saveAs: { filename ->
                      if (filename.indexOf(".csv") > 0) filename
                      else null
                }

    input:
    file featcts from ch_feat_counts_version.first().ifEmpty([])
    file pycoqc from ch_stringtie_version.first().ifEmpty([])

    output:
    file 'software_versions_mqc.yaml' into software_versions_yaml
    file "software_versions.csv"

    script:
    """
    echo $workflow.manifest.version > pipeline.version
    echo $workflow.nextflow.version > nextflow.version
    scrape_software_versions.py > software_versions_mqc.yaml
    """
}

def create_workflow_summary(summary) {
    def yaml_file = workDir.resolve('workflow_summary_mqc.yaml')
    yaml_file.text  = """
    id: 'nf-core-nanornabam-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/nanornabam Workflow Summary'
    section_href: 'https://github.com/nf-core/nanornabam'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
${summary.collect { k,v -> "            <dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }.join("\n")}
        </dl>
    """.stripIndent()

   return yaml_file
}

/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/nanornabam] Successful: $workflow.runName"
    if(!workflow.success){
      subject = "[nf-core/nanornabam] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if(workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if(workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if(workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    if(workflow.container) email_fields['summary']['Docker image'] = workflow.container
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // TODO nf-core: If not using MultiQC, strip out this code (including params.maxMultiqcEmailFileSize)
    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList){
                log.warn "[nf-core/nanornabam] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nf-core/nanornabam] Could not attach MultiQC report to summary email"
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: params.email, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.maxMultiqcEmailFileSize.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (params.email) {
        try {
          if( params.plaintext_email ){ throw GroovyException('Send plaintext e-mail, not HTML') }
          // Try to send HTML e-mail using sendmail
          [ 'sendmail', '-t' ].execute() << sendmail_html
          log.info "[nf-core/nanornabam] Sent summary e-mail to $params.email (sendmail)"
        } catch (all) {
          // Catch failures and try with plaintext
          [ 'mail', '-s', subject, params.email ].execute() << email_txt
          log.info "[nf-core/nanornabam] Sent summary e-mail to $params.email (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File( "${params.outdir}/pipeline_info/" )
    if( !output_d.exists() ) {
      output_d.mkdirs()
    }
    def output_hf = new File( output_d, "pipeline_report.html" )
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File( output_d, "pipeline_report.txt" )
    output_tf.withWriter { w -> w << email_txt }

    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
        log.info "${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}"
        log.info "${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCount} ${c_reset}"
        log.info "${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCount} ${c_reset}"
    }

    if(workflow.success){
        log.info "${c_purple}[nf-core/nanornabam]${c_green} Pipeline completed successfully${c_reset}"
    } else {
        checkHostname()
        log.info "${c_purple}[nf-core/nanornabam]${c_red} Pipeline completed with errors${c_reset}"
    }

}


def nfcoreHeader(){
    // Log colors ANSI codes
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";

    return """    ${c_dim}----------------------------------------------------${c_reset}
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/nanornabam v${workflow.manifest.version}${c_reset}
    ${c_dim}----------------------------------------------------${c_reset}
    """.stripIndent()
}

def checkHostname(){
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if(params.hostnames){
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if(hostname.contains(hname) && !workflow.profile.contains(prof)){
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}
