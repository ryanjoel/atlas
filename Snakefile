import json
import os
from glob import glob
from subprocess import check_output


def read_count(fastq):
    total = 0
    count_file = fastq + '.count'
    if os.path.exists(fastq) and os.path.getsize(fastq) > 100:
        if not os.path.exists(count_file):
            check_output("awk '{n++}END{print n/4}' %s > %s" % (fastq, fastq + '.count'), shell=True)
        with open(count_file) as fh:
            for line in fh:
                total = int(line.strip())
                break
    return total


def get_samples(path, coverage_cutoff=1000):
    """Expecting files with .fastq and a naming convention like <sample>_R1.fastq and
    <sample>_R2.fastq.
    """
    samples = set()
    for f in os.listdir(path):
        if f.endswith("fastq") and ("_r1" in f or "_R1" in f):
            if read_count(os.path.join(path, f)) > coverage_cutoff:
                samples.add(f.partition(".")[0].partition("_")[0])
    return samples


def pattern_search(path, patterns):
    """Grab files under path that match pattern."""
    files = []
    for pattern in patterns:
        files.extend(glob("%s/%s" % (path, pattern)))
    return [os.path.basename(i) for i in files]


def get_count_tables(config, key):
    expected_tables = []
    for name, vals in config[key].items():
        if name.lower() == "taxonomy":
            tax_levels = vals.get("levels", ["species"])
            for level in tax_levels:
                level = level.lower()
                tax_name = "taxonomy_%s" % level
                for subname, subvals in vals.items():
                    if subname.lower() == "levels": continue
                    expected_tables.append("%s_%s" % (subname, tax_name))
        else:
            expected_tables.append(name)
    return expected_tables


SAMPLES = get_samples(os.path.join("data", config["eid"]), 200)
TABLES = get_count_tables(config, "summary_counts")


rule all:
    input:
        expand("results/{eid}/{sample}/quality_control/decontamination/{sample}_{decon_dbs}.fastq.gz", eid=config["eid"], sample=SAMPLES, decon_dbs=list(config["contamination_filtering"]["references"].keys())),
        expand("results/{eid}/{sample}/quality_control/decontamination/{sample}_refstats.txt", eid=config["eid"], sample=SAMPLES),
        expand("results/{eid}/{sample}/quality_control/fastqc/{sample}_final_fastqc.zip", eid=config["eid"], sample=SAMPLES),
        expand("results/{eid}/{sample}/quality_control/fastqc/{sample}_final_fastqc.html", eid=config["eid"], sample=SAMPLES),
        expand("results/{eid}/{sample}/assembly/{sample}_contigs.fasta", eid=config["eid"], sample=SAMPLES),
        expand("results/{eid}/{sample}/annotation/orfs/{sample}.faa", eid=config["eid"], sample=SAMPLES),
        expand("results/{eid}/{sample}/assembly/stats/prefilter_contig_stats.txt", eid=config["eid"], sample=SAMPLES),
        expand("results/{eid}/{sample}/assembly/stats/final_contig_stats.txt", eid=config["eid"], sample=SAMPLES),
        expand("results/{eid}/{sample}/annotation/{reference}/{sample}_hits.tsv", eid=config["eid"], reference=list(config["annotation"]["references"].keys()), sample=SAMPLES),
        expand("results/{eid}/{sample}/annotation/{reference}/{sample}_assignments.tsv", eid=config["eid"], reference=list(config["annotation"]["references"].keys()), sample=SAMPLES),
        expand("results/{eid}/{sample}/annotation/{sample}_merged_assignments.tsv", eid=config["eid"], sample=SAMPLES),
        expand("results/{eid}/{sample}/count_tables/{sample}_{table}.tsv", eid=config["eid"], sample=SAMPLES, table=TABLES)


rule quality_filter_reads:
    """This needs to be reconfigured to allow multiple input locations."""
    input:
        r1 = "data/{eid}/{sample}_R1.fastq",
        r2 = "data/{eid}/{sample}_R2.fastq"
    output:
        r1 = "results/{eid}/{sample}/quality_control/quality_filter/{sample}_R1.fastq",
        r2 = "results/{eid}/{sample}/quality_control/quality_filter/{sample}_R2.fastq",
        stats = "results/{eid}/{sample}/logs/{sample}_quality_filtering_stats.txt"
    params:
        lref = config["filtering"]["adapters"],
        rref = config["filtering"]["adapters"],
        mink = config["filtering"].get("mink", "8"),
        trimq = config["filtering"].get("minimum_base_quality", "10"),
        hdist = config["filtering"].get("allowable_kmer_mismatches", "1"),
        k = config["filtering"].get("reference_kmer_match_length", "31"),
        qtrim = "rl",
        minlength = config["filtering"].get("minimum_passing_read_length", "51"),
        # read complexity filter
        minbasefrequency = config["filtering"].get("min_base_frequency", 0.05)
    threads:
        config.get("threads", 1)
    shell:
        """bbduk2.sh -Xmx8g in={input.r1} in2={input.r2} out={output.r1} out2={output.r2} \
               rref={params.rref} lref={params.lref} mink={params.mink} \
               stats={output.stats} hdist={params.hdist} k={params.k} \
               trimq={params.trimq} qtrim={params.qtrim} threads={threads} \
               minlength={params.minlength} minbasefrequency={params.minbasefrequency} \
               overwrite=true"""


rule join_reads:
    input:
        r1 = "results/{eid}/{sample}/quality_control/quality_filter/{sample}_R1.fastq",
        r2 = "results/{eid}/{sample}/quality_control/quality_filter/{sample}_R2.fastq"
    output:
        joined = "results/{eid}/{sample}/quality_control/join/{sample}.extendedFrags.fastq",
        hist = "results/{eid}/{sample}/quality_control/join/{sample}.hist",
        failed_r1 = "results/{eid}/{sample}/quality_control/join/{sample}.notCombined_1.fastq",
        failed_r2 = "results/{eid}/{sample}/quality_control/join/{sample}.notCombined_2.fastq"
    shadow:
        "shallow"
    params:
        output_dir = lambda wc: "results/%s/%s/quality_control/join/" % (wc.eid, wc.sample),
        min_overlap = config["merging"].get("minimum_overlap", "30"),
        max_overlap = config["merging"].get("maximum_overlap", "250"),
        max_mismatch_density = config["merging"].get("maximum_mismatch_density", "0.25"),
        phred_offset = config.get("phred_offset", "33")
    log:
        "results/{eid}/{sample}/logs/{sample}_join.log"
    threads:
        config.get("threads", 1)
    shell:
        """flash {input.r1} {input.r2} --min-overlap {params.min_overlap} \
               --max-overlap {params.max_overlap} --max-mismatch-density {params.max_mismatch_density} \
               --phred-offset {params.phred_offset} --output-prefix {wildcards.sample} \
               --output-directory {params.output_dir} --threads {threads}"""


rule concatenate_joined_reads:
    input:
        joined = "results/{eid}/{sample}/quality_control/join/{sample}.extendedFrags.fastq",
        failed_r1 = "results/{eid}/{sample}/quality_control/join/{sample}.notCombined_1.fastq",
        failed_r2 = "results/{eid}/{sample}/quality_control/join/{sample}.notCombined_2.fastq"
    output:
        "results/{eid}/{sample}/quality_control/join/{sample}_joined.fastq"
    shell:
        "cat {input.joined} {input.failed_r1} {input.failed_r2} > {output}"


rule error_correction:
    input:
        "results/{eid}/{sample}/quality_control/join/{sample}_joined.fastq"
    output:
        "results/{eid}/{sample}/quality_control/error_correction/{sample}_corrected.fastq.gz"
    threads:
        config.get("threads", 1)
    shell:
        "tadpole.sh in={input} out={output} mode=correct threads={threads}"


if config.get("qual_method") == "expected_error":
    rule subset_reads_by_quality:
        input: "results/{eid}/{sample}/quality_control/error_correction/{sample}_corrected.fastq.gz"
        output: "results/{eid}/{sample}/quality_control/quality_filter/{sample}_filtered.fastq"
        params:
            phred = config.get("phred_offset", 33),
            maxee = config["filtering"].get("maximum_expected_error", 2),
            maxns = config["filtering"].get("maxns", 3)
        threads:
            1
        shell: """vsearch --fastq_filter {input} --fastqout {output} --fastq_ascii {params.phred} \
                      --fastq_maxee {params.maxee} --fastq_maxns {params.maxns}"""
else:
    rule subset_reads_by_quality:
        input:
            "results/{eid}/{sample}/quality_control/error_correction/{sample}_corrected.fastq.gz"
        output:
            "results/{eid}/{sample}/quality_control/quality_filter/{sample}_filtered.fastq"
        params:
            adapter_clip = "" if not config["filtering"].get("adapters", "") else "ILLUMINACLIP:%s:%s" % (config["filtering"]["adapters"], config["filtering"].get("adapter_clip", "2:30:10")),
            window_size_qual = "" if not config["filtering"].get("window_size_quality", "") else "SLIDINGWINDOW:%s" % config["filtering"]["window_size_quality"],
            leading = "" if not config["filtering"].get("leading", 0) else "LEADING:%s" % config["filtering"]["leading"],
            trailing = "" if not config["filtering"].get("trailing", 0) else "TRAILING:%s" % config["filtering"]["trailing"],
            crop = "" if not config["filtering"].get("crop", 0) else "CROP:%s" % config["filtering"]["crop"],
            headcrop = "" if not config["filtering"].get("headcrop", 0) else "HEADCROP:%s" % config["filtering"]["headcrop"],
            minlen = "MINLEN:%s" % config["filtering"]["minimum_passing_read_length"]
        threads:
            config.get("threads", 1)
        shell:
            """trimmomatic SE -threads {threads} {input} {output} {params.adapter_clip} \
                   {params.leading} {params.trailing} {params.window_size_qual} {params.minlen}"""


rule decontaminate_joined:
    input:
        "results/{eid}/{sample}/quality_control/quality_filter/{sample}_filtered.fastq"
    output:
        dbs = ["results/{eid}/{sample}/quality_control/decontamination/{sample}_%s.fastq.gz" % db for db in list(config["contamination_filtering"]["references"].keys())],
        stats = "results/{eid}/{sample}/quality_control/decontamination/{sample}_refstats.txt",
        clean = "results/{eid}/{sample}/quality_control/decontamination/{sample}_clean.fastq.gz"
    params:
        refs_in = " ".join(["ref_%s=%s" % (n, fa) for n, fa in config["contamination_filtering"]["references"].items()]),
        refs_out = lambda wc: " ".join(["out_%s=results/%s/%s/quality_control/decontamination/%s_%s.fastq.gz" % (n, wc.eid, wc.sample, wc.sample, n) for n in list(config["contamination_filtering"]["references"].keys())]),
        maxindel = config["contamination_filtering"].get("maxindel", 20),
        minratio = config["contamination_filtering"].get("minratio", 0.65),
        minhits = config["contamination_filtering"].get("minhits", 1),
        ambiguous = config["contamination_filtering"].get("ambiguous", "best"),
        k = config["contamination_filtering"].get("k", 15)
    threads:
        config.get("threads", 1)
    shell:
        """bbsplit.sh {params.refs_in} in={input} outu={output.clean} \
               {params.refs_out} maxindel={params.maxindel} minratio={params.minratio} \
               minhits={params.minhits} ambiguous={params.ambiguous} refstats={output.stats}\
               threads={threads} k={params.k} local=t"""


if config["data_type"] == "metatranscriptome":
    rule ribosomal_rna:
        input:
            "results/{eid}/{sample}/quality_control/decontamination/{sample}_clean.fastq.gz"
        output:
            "results/{eid}/{sample}/quality_control/decontamination/{sample}_final.fastq.gz"
        shell:
            "cp {input} {output}"
else:
    rule ribosomal_rna:
        input:
            clean = "results/{eid}/{sample}/quality_control/decontamination/{sample}_clean.fastq.gz",
            rrna = "results/{eid}/{sample}/quality_control/decontamination/{sample}_rRNA.fastq.gz"
        output:
            "results/{eid}/{sample}/quality_control/decontamination/{sample}_final.fastq.gz"
        shell:
            "cat {input.clean} {input.rrna} > {output}"


rule fastqc:
    input:
        "results/{eid}/{sample}/quality_control/decontamination/{sample}_final.fastq.gz"
    output:
        "results/{eid}/{sample}/quality_control/fastqc/{sample}_final_fastqc.zip",
        "results/{eid}/{sample}/quality_control/fastqc/{sample}_final_fastqc.html"
    params:
        output_dir = lambda wc: "results/%s/%s/quality_control/fastqc/" % (wc.eid, wc.sample)
    threads:
        config.get("threads", 1)
    shell:
        "fastqc -t {threads} -f fastq -o {params.output_dir} {input}"


rule megahit_assembly:
    input:
        "results/{eid}/{sample}/quality_control/decontamination/{sample}_final.fastq.gz"
    output:
        "results/{eid}/{sample}/assembly/{sample}_prefilter.contigs.fa"
    params:
        memory = config["assembly"].get("memory", 0.90),
        min_count = config["assembly"].get("minimum_count", 2),
        k_min = config["assembly"].get("kmer_min", 21),
        k_max = config["assembly"].get("kmer_max", 121),
        k_step = config["assembly"].get("kmer_step", 20),
        merge_level = config["assembly"].get("merge_level", "20,0.98"),
        prune_level = config["assembly"].get("prune_level", 2),
        low_local_ratio = config["assembly"].get("low_local_ratio", 0.2),
        min_contig_len = config["assembly"].get("minimum_contig_length", 200),
        outdir = lambda wc: "results/%s/%s/assembly" % (wc.eid, wc.sample)
    threads:
        config.get("threads", 1)
    log:
        "results/{eid}/{sample}/assembly/{sample}.log"
    shell:
        """megahit --num-cpu-threads {threads} --read {input} --continue \
               --k-min {params.k_min} --k-max {params.k_max} --k-step {params.k_step} \
               --out-dir {params.outdir} --out-prefix {wildcards.sample}_prefilter \
               --min-contig-len {params.min_contig_len} --min-count {params.min_count} \
               --merge-level {params.merge_level} --prune-level {params.prune_level} \
               --low-local-ratio {params.low_local_ratio}"""


rule dirty_contigs_stats:
    input:
        "results/{eid}/{sample}/assembly/{sample}_prefilter.contigs.fa"
    output:
        "results/{eid}/{sample}/assembly/stats/prefilter_contig_stats.txt"
    shell:
        "stats.sh in={input} format=3 > {output}"


rule dirty_contig_coverage_stats:
    input:
        fasta = "results/{eid}/{sample}/assembly/{sample}_prefilter.contigs.fa",
        fastq = "results/{eid}/{sample}/quality_control/decontamination/{sample}_final.fastq.gz"
    output:
        bhist = "results/{eid}/{sample}/assembly/stats/prefilter_base_composition.txt",
        bqhist = "results/{eid}/{sample}/assembly/stats/prefilter_box_quality.txt",
        mhist = "results/{eid}/{sample}/assembly/stats/prefilter_mutation_rates.txt",
        statsfile = "results/{eid}/{sample}/assembly/stats/prefilter_mapping_stats.txt",
        covstats = "results/{eid}/{sample}/assembly/stats/prefilter_coverage_stats.txt"
    threads:
        config.get("threads", 1)
    shell:
        """bbmap.sh nodisk=t ref={input.fasta} in={input.fastq} fast=t threads={threads} \
               bhist={output.bhist} bqhist={output.bqhist} mhist={output.mhist} \
               statsfile={output.statsfile} covstats={output.covstats}"""


rule filter_by_coverage:
    input:
        fasta = "results/{eid}/{sample}/assembly/{sample}_prefilter.contigs.fa",
        covstats = "results/{eid}/{sample}/assembly/stats/prefilter_coverage_stats.txt"
    output:
        fasta = "results/{eid}/{sample}/assembly/{sample}_contigs.fasta",
        removed_names = "results/{eid}/{sample}/assembly/{sample}_discarded_contigs.txt"
    params:
        minc = config["assembly"].get("minc", 5),
        minp = config["assembly"].get("minp", 40),
        minr = config["assembly"].get("minr", 0),
        minl = config["assembly"].get("minl", 1),
        trim = config["assembly"].get("trim", 0)
    threads:
        1
    shell:
        """filterbycoverage.sh in={input.fasta} cov={input.covstats} out={output.fasta} \
               outd={output.removed_names} minc={params.minc} minp={params.minp} \
               minr={params.minr} minl={params.minl} trim={params.trim}"""


rule contig_coverage_stats:
    input:
        fasta = "results/{eid}/{sample}/assembly/{sample}_contigs.fasta",
        fastq = "results/{eid}/{sample}/quality_control/decontamination/{sample}_final.fastq.gz"
    output:
        bam = "results/{eid}/{sample}/annotation/{sample}.bam",
        bai = "results/{eid}/{sample}/annotation/{sample}.bam.bai",
        bhist = "results/{eid}/{sample}/assembly/stats/postfilter_base_composition.txt",
        bqhist = "results/{eid}/{sample}/assembly/stats/postfilter_box_quality.txt",
        mhist = "results/{eid}/{sample}/assembly/stats/postfilter_mutation_rates.txt",
        gchist = "results/{eid}/{sample}/assembly/stats/postfilter_gc_rates.txt",
        statsfile = "results/{eid}/{sample}/assembly/stats/postfilter_mapping_stats.txt",
        covstats = "results/{eid}/{sample}/assembly/stats/postfilter_coverage_stats.txt"
    threads:
        config.get("threads", 1)
    shell:
        """bbmap.sh nodisk=t ref={input.fasta} in={input.fastq} \
               out=results/{wildcards.eid}/{wildcards.sample}/annotation/{wildcards.sample}.sam \
               mappedonly=t threads={threads} bhist={output.bhist} bqhist={output.bqhist} \
               mhist={output.mhist} gchist={output.gchist} statsfile={output.statsfile} \
               covstats={output.covstats}
           samtools view -@ {threads} -bSh1 "results/{wildcards.eid}/{wildcards.sample}/annotation/{wildcards.sample}.sam" \
               | samtools sort -@ {threads} -T results/{wildcards.eid}/{wildcards.sample}/annotation/{wildcards.sample} -o {output.bam} -O bam -
           samtools index {output.bam}"""


rule final_contigs_stats:
    input:
        "results/{eid}/{sample}/assembly/{sample}_contigs.fasta"
    output:
        "results/{eid}/{sample}/assembly/stats/final_contig_stats.txt"
    shell:
        "stats.sh in={input} format=3 > {output}"


rule prodigal_orfs:
    input:
        "results/{eid}/{sample}/assembly/{sample}_contigs.fasta"
    output:
        prot = "results/{eid}/{sample}/annotation/orfs/{sample}.faa",
        nuc = "results/{eid}/{sample}/annotation/orfs/{sample}.fna",
        gff = "results/{eid}/{sample}/annotation/orfs/{sample}.gff"
    params:
        g = config["annotation"].get("translation_table", "11")
    shell:
        """prodigal -i {input} -o {output.gff} -f gff -a {output.prot} -d {output.nuc} \
               -g {params.g} -p meta"""


rule gff_to_gtf:
    input:
        "results/{eid}/{sample}/annotation/orfs/{sample}.gff"
    output:
        "results/{eid}/{sample}/annotation/orfs/{sample}.gtf"
    run:
        import re
        t = re.compile(r'ID=[0-9]+_([0-9]+);')
        with open(output[0], "w") as fh, open(input[0]) as gff:
            print("##gff-version  3", file=fh)
            for line in gff:
                if line.startswith("#"): continue
                toks = line.strip().split("\t")
                orf = t.findall(toks[-1])[0]
                gene_id = toks[0] + "_" + orf
                toks[-1] = toks[-1] + "gene_id " + gene_id + ";"
                print(*toks, sep="\t", file=fh)


rule counts_per_region:
    input:
        gtf = "results/{eid}/{sample}/annotation/orfs/{sample}.gtf",
        bam = "results/{eid}/{sample}/annotation/{sample}.bam"
    output:
        summary = "results/{eid}/{sample}/annotation/orfs/{sample}.CDS.summary.txt",
        counts = "results/{eid}/{sample}/annotation/orfs/{sample}.CDS.txt"
    params:
        min_read_overlap = config["annotation"].get("minimum_overlap", 20)
    threads:
        config.get("threads", 1)
    shell:
        """verse --multithreadDecompress -T {threads} --minReadOverlap {params.min_read_overlap} \
               --singleEnd -t CDS -z 5 -a {input.gtf} \
               -o results/{wildcards.eid}/{wildcards.sample}/annotation/orfs/{wildcards.sample} \
               {input.bam} 2> /dev/null"""


rule build_dmnd_database:
    input:
        lambda wc: config["annotation"]["references"][wc.reference]["fasta"]
    output:
        "databases/annotation/{reference}.dmnd"
    threads:
        config.get("threads", 1)
    shell:
        "diamond makedb --no-auto-append --threads {threads} --in {input} --db {output}"


rule split:
    input:
        "results/{eid}/{sample}/annotation/orfs/{sample}.faa"
    output:
        temp(dynamic("results/{eid}/{sample}/annotation/orfs/{sample}_{n}.faa"))
    params:
        chunk_size = config["annotation"].get("chunk_size", "250000")
    shell:
        "python scripts/fastx.py split-fasta --chunk-size {params.chunk_size} {input}"


rule diamond_alignments:
    input:
        fasta = "results/{eid}/{sample}/annotation/orfs/{sample}_{n}.faa",
        db = "databases/annotation/{reference}.dmnd"
    output:
        temp("results/{eid}/{sample}/annotation/{reference}/{sample}_intermediate_{n}.aln")
    params:
        tmpdir = "--tmpdir %s" % config.get("temporary_directory", "") if config.get("temporary_directory", "") else "",
        top_seqs = lambda wc: config["annotation"]["references"][wc.reference].get("top_seqs", "5"),
        e_value = lambda wc: config["annotation"]["references"][wc.reference].get("e_value", "0.000001"),
        min_identity = lambda wc: config["annotation"]["references"][wc.reference].get("min_identity", "50"),
        query_cover = lambda wc: config["annotation"]["references"][wc.reference].get("query_coverage", "60"),
        gap_open = lambda wc: config["annotation"]["references"][wc.reference].get("gap_open", "11"),
        gap_extend = lambda wc: config["annotation"]["references"][wc.reference].get("gap_extend", "1"),
        block_size = lambda wc: config["annotation"]["references"][wc.reference].get("block_size", "2"),
        index_chunks = lambda wc: config["annotation"]["references"][wc.reference].get("index_chunks", "4"),
        run_mode = lambda wc: "" if config["annotation"]["references"][wc.reference].get("run_mode", "fast") == "fast" else "--more-sensitive"
    threads:
        config.get("threads", 1)
    shell:
        """diamond blastp --threads {threads} --outfmt 6 --out {output} \
               --query {input.fasta} --db {input.db} --top {params.top_seqs} \
               --evalue {params.e_value} --id {params.min_identity} \
               --query-cover {params.query_cover} {params.run_mode} --gapopen {params.gap_open} \
               --gapextend {params.gap_extend} {params.tmpdir} --block-size {params.block_size} \
               --index-chunks {params.index_chunks}"""


rule merge_alignments:
    input:
        dynamic("results/{eid}/{sample}/annotation/{reference}/{sample}_intermediate_{n}.aln")
    output:
        "results/{eid}/{sample}/annotation/{reference}/{sample}_hits.tsv"
    shell:
        "cat {input} | sort -k1,1 -k12,12rn > {output}"


rule parse_blast:
    input:
        "results/{eid}/{sample}/annotation/{reference}/{sample}_hits.tsv"
    output:
        "results/{eid}/{sample}/annotation/{reference}/{sample}_assignments.tsv"
    params:
        subcommand = lambda wc: "refseq" if "refseq" in wc.reference else "eggnog",
        namemap = lambda wc: config["annotation"]["references"][wc.reference]["namemap"],
        treefile = lambda wc: config["annotation"]["references"][wc.reference].get("tree", ""),
        summary_method = lambda wc: config["annotation"]["references"][wc.reference].get("summary_method", "best"),
        aggregation_method = lambda wc: "--aggregation-method %s" % config["annotation"]["references"][wc.reference].get("aggregation_method", "") if "refseq" in wc.reference else "",
        majority_threshold = lambda wc: "--majority-threshold %f" % config["annotation"]["references"][wc.reference].get("majority_threshold", 0.51) if "refseq" in wc.reference else "",
        min_identity = lambda wc: config["annotation"]["references"][wc.reference].get("min_identity", "50"),
        min_bitscore = lambda wc: config["annotation"]["references"][wc.reference].get("min_bitscore", "0"),
        min_length = lambda wc: config["annotation"]["references"][wc.reference].get("min_length", "60"),
        max_evalue = lambda wc: config["annotation"]["references"][wc.reference].get("max_evalue", "0.000001"),
        max_hits = lambda wc: config["annotation"]["references"][wc.reference].get("max_hits", "10"),
        top_fraction = lambda wc: config["annotation"]["references"][wc.reference].get("top_fraction", "0.50")
    shell:
        """python scripts/blast2assignment.py {params.subcommand} \
               --summary-method {params.summary_method} {params.aggregation_method} \
               {params.majority_threshold} --min-identity {params.min_identity} \
               --min-bitscore {params.min_bitscore} --min-length {params.min_length} \
               --max-evalue {params.max_evalue} --max-hits {params.max_hits} \
               --top-fraction {params.top_fraction} {input} {params.namemap} {params.treefile} \
               {output}"""


rule merge_blast:
    input:
        ["results/{eid}/{sample}/annotation/%s/{sample}_assignments.tsv" % i for i in list(config["annotation"]["references"].keys())]
    output:
        "results/{eid}/{sample}/annotation/{sample}_merged_assignments.tsv"
    shell:
        "python scripts/blast2assignment.py merge-tables {input} {output}"


rule aggregate_counts:
    input:
        merged = "results/{eid}/{sample}/annotation/{sample}_merged_assignments.tsv",
        counts = "results/{eid}/{sample}/annotation/orfs/{sample}.CDS.txt"
    output:
        "results/{eid}/{sample}/count_tables/{sample}_{table}.tsv"
    params:
        prefix = lambda wc: "results/%s/%s/counts/%s" % (wc.eid, wc.sample, wc.sample),
        combos = json.dumps(config["summary_counts"])
    shell:
        """python scripts/blast2assignment.py counts {params.prefix} {input.merged} \
               {input.counts} '{params.combos}'"""
