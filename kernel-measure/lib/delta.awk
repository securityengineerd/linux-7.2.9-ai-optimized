# Exact integer before/after math for the kernel-measure harness.
# Uses only awk so the core deltas do not need python3, bc, or gawk.
# mawk and gawk both accept split(s, a, "").
#
# modes:
#   selftest
#   elapsed   -v start=NS -v end=NS
#   vmstat    before after, -v metrics=FILE
#   schedstat before after, -v metrics=FILE [-v schedstats=on|off|...]
#   perf      perf.csv,    -v metrics=FILE
#   table     before.env after.env [-v rows="key|label,key|label,..."]
#             [-v extra_prefix=wl_]  also show every key with that prefix
#             present in either file (workload-reported metrics)

function fail(msg) {
    printf "selftest fail: %s\n", msg > "/dev/stderr"
    exit_code = 1
    exit 1
}

function strip0(s) {
    sub(/^0+/, "", s)
    if (s == "")
        return "0"
    return s
}

function norm(s) {
    gsub(/[[:space:]]/, "", s)
    if (s == "" || s == "+" || s == "-")
        return "0"
    neg = 0
    if (sub(/^-/, "", s))
        neg = 1
    sub(/^\+/, "", s)
    s = strip0(s)
    if (s == "0" || neg == 0)
        return s
    return "-" s
}

function cmp(a, b) {
    a = strip0(a)
    b = strip0(b)
    if (length(a) < length(b))
        return -1
    if (length(a) > length(b))
        return 1
    if (a == b)
        return 0
    return (a < b) ? -1 : 1
}

function addpos(a, b,    i, j, A, B, nA, nB, carry, d, out, da, db, tmp) {
    a = strip0(a)
    b = strip0(b)
    if (length(a) < length(b)) {
        tmp = a
        a = b
        b = tmp
    }
    nA = split(a, A, "")
    nB = split(b, B, "")
    i = nA
    j = nB
    carry = 0
    out = ""
    while (i > 0) {
        da = A[i] + 0
        db = (j > 0) ? (B[j] + 0) : 0
        d = da + db + carry
        carry = int(d / 10)
        d = d - (carry * 10)
        out = d out
        i--
        j--
    }
    if (carry > 0)
        out = carry out
    return strip0(out)
}

function subpos(a, b,    i, j, A, B, nA, nB, borrow, d, out, da, db) {
    a = strip0(a)
    b = strip0(b)
    nA = split(a, A, "")
    nB = split(b, B, "")
    i = nA
    j = nB
    borrow = 0
    out = ""
    while (i > 0) {
        da = A[i] + 0
        db = (j > 0) ? (B[j] + 0) : 0
        d = da - borrow - db
        if (d < 0) {
            d += 10
            borrow = 1
        } else {
            borrow = 0
        }
        out = d out
        i--
        j--
    }
    return strip0(out)
}

function subint(a, b,    na, nb, sa, sb, c) {
    a = norm(a)
    b = norm(b)
    sa = (a ~ /^-/)
    sb = (b ~ /^-/)
    na = sa ? substr(a, 2) : a
    nb = sb ? substr(b, 2) : b
    if (!sa && !sb) {
        c = cmp(na, nb)
        if (c == 0)
            return "0"
        if (c > 0)
            return subpos(na, nb)
        return "-" subpos(nb, na)
    }
    if (sa && sb) {
        c = cmp(nb, na)
        if (c == 0)
            return "0"
        if (c > 0)
            return subpos(nb, na)
        return "-" subpos(na, nb)
    }
    if (!sa && sb)
        return addpos(na, nb)
    return "-" addpos(na, nb)
}

function addint(a, b,    na, nb, sa, sb) {
    a = norm(a)
    b = norm(b)
    if (a == "0")
        return b
    if (b == "0")
        return a
    sa = (a ~ /^-/)
    sb = (b ~ /^-/)
    na = sa ? substr(a, 2) : a
    nb = sb ? substr(b, 2) : b
    if (!sa && !sb)
        return addpos(na, nb)
    if (sa && sb)
        return "-" addpos(na, nb)
    if (sa && !sb)
        return subint(nb, na)
    return subint(na, nb)
}

function ns_to_sec(ns,    neg, whole, frac, L) {
    ns = norm(ns)
    neg = (ns ~ /^-/)
    if (neg)
        ns = substr(ns, 2)
    if (ns == "0")
        return "0.000"
    L = length(ns)
    if (L <= 9) {
        while (length(ns) < 9)
            ns = "0" ns
        whole = "0"
        frac = substr(ns, 1, 3)
    } else {
        whole = substr(ns, 1, L - 9)
        frac = substr(ns, L - 8, 3)
    }
    return (neg ? "-" : "") whole "." frac
}

function is_num(s) {
    return s ~ /^-?[0-9]+(\.[0-9]+)?$/
}

function emit(k, v) {
    if (metrics != "")
        printf "%s=%s\n", k, v >> metrics
}

function load_kv(file, arr,    line, k, v) {
    while ((getline line < file) > 0) {
        if (line ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
            k = line
            sub(/=.*/, "", k)
            v = line
            sub(/^[^=]*=/, "", v)
            arr[k] = v
        }
    }
    close(file)
}

function pct(before, after, delta,    n, d) {
    if (!is_num(before) || !is_num(after) || !is_num(delta))
        return "n/a"
    if (norm(before) == "0")
        return "n/a"
    if (length(strip0(before)) > 15 || length(strip0(after)) > 15)
        return "n/a"
    n = after - before
    d = before + 0
    if (d == 0)
        return "n/a"
    return sprintf("%+.2f%%", (n / d) * 100)
}

function show_delta(before, after) {
    if (!is_num(before) || !is_num(after))
        return "n/a"
    if (before ~ /\./ || after ~ /\./) {
        return sprintf("%.6f", after - before)
    }
    return subint(after, before)
}

BEGIN {
    exit_code = 0
    if (mode == "selftest") {
        if (subint("1000", "999") != "1")
            fail("1000-999")
        if (subint("5", "8") != "-3")
            fail("5-8")
        if (subint("8", "5") != "3")
            fail("8-5")
        if (subint("0", "0") != "0")
            fail("0-0")
        if (addint("999", "1") != "1000")
            fail("999+1")
        if (addint("-5", "3") != "-2")
            fail("-5+3")
        if (addint("3", "-5") != "-2")
            fail("3+-5")
        if (subint("10000000000000000000", "1") != "9999999999999999999")
            fail("bigint sub")
        if (addint("9999999999999999999", "1") != "10000000000000000000")
            fail("bigint add")
        if (ns_to_sec(subint("1690000001500000000", "1690000000000000000")) != "1.500")
            fail("elapsed 1.500")
        if (ns_to_sec("500000000") != "0.500")
            fail("0.500")
        if (ns_to_sec("5000000000") != "5.000")
            fail("5.000")
        print "ok"
        exit 0
    }
    if (mode == "elapsed") {
        print ns_to_sec(subint(end, start))
        exit 0
    }
    if (metrics != "")
        printf "" > metrics
}

function want_vmstat(k) {
    if (k == "compact_stall" || k == "compact_success")
        return 1
    if (k == "thp_fault_alloc" || k == "thp_fault_fallback" || k == "numa_hint_faults")
        return 1
    if (k ~ /^pgscan/ || k ~ /^pgsteal/)
        return 1
    return 0
}

file == 0 { file = 1 }

mode == "vmstat" && FNR == 1 && NR != 1 { file = 2 }

mode == "vmstat" && file == 1 && NF >= 2 && $2 ~ /^-?[0-9]+$/ { vb[$1] = $2; vseen[$1] = 1 }
mode == "vmstat" && file == 2 && NF >= 2 && $2 ~ /^-?[0-9]+$/ { va[$1] = $2; vseen[$1] = 1 }

mode == "schedstat" && FNR == 1 && NR != 1 { file = 2 }

mode == "schedstat" && file == 1 && $1 == "version" { ver_b = $2 }
mode == "schedstat" && file == 2 && $1 == "version" { ver_a = $2 }
mode == "schedstat" && $1 ~ /^cpu[0-9]+$/ && NF >= 10 {
    cpu = $1
    if (file == 1) {
        sb_sched[cpu] = $4
        sb_idle[cpu] = $5
        sb_ttwu[cpu] = $6
        sb_ttwul[cpu] = $7
        sb_delay[cpu] = $9
        sb_pcount[cpu] = $10
        scpu[cpu] = 1
    } else {
        sa_sched[cpu] = $4
        sa_idle[cpu] = $5
        sa_ttwu[cpu] = $6
        sa_ttwul[cpu] = $7
        sa_delay[cpu] = $9
        sa_pcount[cpu] = $10
        scpu[cpu] = 1
    }
}

function known_event(ev) {
    # Accept both canonical and lowercase aliases that perf list prints.
    return ev == "cycles" || ev == "instructions" || ev == "cache-references" || ev == "cache-misses" || ev == "LLC-load-misses" || ev == "llc-load-misses" || ev == "dTLB-load-misses" || ev == "dtlb-load-misses" || ev == "iTLB-load-misses" || ev == "itlb-load-misses" || ev == "context-switches" || ev == "cpu-migrations" || ev == "mem_load_retired.l3_miss" || ev == "mem_load_retired.l3_hit" || ev == "longest_lat_cache.miss"
}

function canon_event(ev) {
    if (ev == "llc-load-misses") return "LLC-load-misses"
    if (ev == "dtlb-load-misses") return "dTLB-load-misses"
    if (ev == "itlb-load-misses") return "iTLB-load-misses"
    return ev
}

mode == "perf" {
    if ($0 ~ /^#/ || $0 ~ /^[[:space:]]*$/)
        next
    n = split($0, f, ",")
    if (n < 1)
        next
    ev = ""
    for (i = 1; i <= n; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", f[i])
        # perf appends :u / :k etc. when perf_event_paranoid limits scope
        sub(/:[ukhHGp]+$/, "", f[i])
        if (known_event(f[i])) {
            ev = canon_event(f[i])
            break
        }
    }
    if (ev == "")
        next
    val = "n/a"
    for (i = 1; i <= n && f[i] != ev; i++) {
        if (is_num(f[i])) {
            val = f[i]
            break
        }
    }
    perf[ev] = val
}

function kv_or_na(arr, k) {
    if (!(k in arr) || arr[k] == "")
        return "n/a"
    return arr[k]
}

END {
    if (exit_code != 0)
        exit exit_code
    if (mode == "vmstat") {
        print "# vmstat deltas (after - before)"
        print "# summed keys are every pgscan* and pgsteal* counter present in both snapshots"
        nkeys = 0
        for (k in vseen)
            keys[++nkeys] = k
        # insertion sort, n is tiny
        for (i = 1; i <= nkeys; i++) {
            for (j = i + 1; j <= nkeys; j++) {
                if (keys[j] < keys[i]) {
                    tmp = keys[i]
                    keys[i] = keys[j]
                    keys[j] = tmp
                }
            }
        }
        sum_pgscan = "0"
        sum_pgsteal = "0"
        seen_pgscan = 0
        seen_pgsteal = 0
        for (i = 1; i <= nkeys; i++) {
            k = keys[i]
            if (!want_vmstat(k))
                continue
            if (!(k in vb) || !(k in va)) {
                printf "%s n/a\n", k
                continue
            }
            d = subint(va[k], vb[k])
            printf "%s %s\n", k, d
            if (k ~ /^pgscan/) {
                sum_pgscan = addint(sum_pgscan, d)
                seen_pgscan = 1
            }
            if (k ~ /^pgsteal/) {
                sum_pgsteal = addint(sum_pgsteal, d)
                seen_pgsteal = 1
            }
        }
        pgscan_out = seen_pgscan ? sum_pgscan : "n/a"
        pgsteal_out = seen_pgsteal ? sum_pgsteal : "n/a"
        printf "sum_pgscan %s\n", pgscan_out
        printf "sum_pgsteal %s\n", pgsteal_out
        emit("pgscan_delta", pgscan_out)
        emit("pgsteal_delta", pgsteal_out)
        emit("compact_stall_delta", (("compact_stall" in vb) && ("compact_stall" in va)) ? subint(va["compact_stall"], vb["compact_stall"]) : "n/a")
        emit("compact_success_delta", (("compact_success" in vb) && ("compact_success" in va)) ? subint(va["compact_success"], vb["compact_success"]) : "n/a")
        emit("thp_fault_alloc_delta", (("thp_fault_alloc" in vb) && ("thp_fault_alloc" in va)) ? subint(va["thp_fault_alloc"], vb["thp_fault_alloc"]) : "n/a")
        emit("thp_fault_fallback_delta", (("thp_fault_fallback" in vb) && ("thp_fault_fallback" in va)) ? subint(va["thp_fault_fallback"], vb["thp_fault_fallback"]) : "n/a")
        emit("numa_hint_faults_delta", (("numa_hint_faults" in vb) && ("numa_hint_faults" in va)) ? subint(va["numa_hint_faults"], vb["numa_hint_faults"]) : "n/a")
        exit 0
    }
    if (mode == "schedstat") {
        print "# runqueue latency method: /proc/schedstat CPU-line deltas"
        print "# perf sched was not used: it needs extra privileges and would add load to the run"
        print "# Linux 7.2.9 kernel/sched/stats.c SCHEDSTAT_VERSION 17 prints:"
        print "#   cpuN yld_count legacy0 sched_count sched_goidle ttwu_count ttwu_local rq_cpu_time run_delay_ns pcount"
        print "# legacy0 is always 0 (O(1) scheduler ABI leftover). Field numbers below are 1-based after the cpu token."
        printf "version_before=%s\n", (ver_b == "" ? "missing" : ver_b)
        printf "version_after=%s\n", (ver_a == "" ? "missing" : ver_a)
        sum_sched = "0"
        sum_idle = "0"
        sum_delay = "0"
        sum_pcount = "0"
        sum_ttwu = "0"
        sum_ttwul = "0"
        cpus = 0
        for (cpu in scpu) {
            if (!(cpu in sb_sched) || !(cpu in sa_sched))
                continue
            if (sb_sched[cpu] == "" || sa_sched[cpu] == "")
                continue
            cpus++
            sum_sched = addint(sum_sched, subint(sa_sched[cpu], sb_sched[cpu]))
            sum_idle = addint(sum_idle, subint(sa_idle[cpu], sb_idle[cpu]))
            sum_delay = addint(sum_delay, subint(sa_delay[cpu], sb_delay[cpu]))
            sum_pcount = addint(sum_pcount, subint(sa_pcount[cpu], sb_pcount[cpu]))
            sum_ttwu = addint(sum_ttwu, subint(sa_ttwu[cpu], sb_ttwu[cpu]))
            sum_ttwul = addint(sum_ttwul, subint(sa_ttwul[cpu], sb_ttwul[cpu]))
        }
        printf "cpus=%d\n", cpus
        if (cpus == 0) {
            print "sched_count_delta=n/a"
            print "sched_goidle_delta=n/a"
            print "run_delay_ns_delta=n/a"
            print "pcount_delta=n/a"
            print "rq_latency_ns=n/a"
            emit("sched_count_delta", "n/a")
            emit("sched_goidle_delta", "n/a")
            emit("run_delay_ns_delta", "n/a")
            emit("pcount_delta", "n/a")
            emit("rq_latency_ns", "n/a")
            emit("ttwu_count_delta", "n/a")
            emit("ttwu_local_delta", "n/a")
            emit("ttwu_remote_delta", "n/a")
            emit("ttwu_remote_frac", "n/a")
            exit 0
        }
        # sched_count, sched_goidle, ttwu_count, ttwu_local are schedstat_inc()
        # counters: they only move while kernel.sched_schedstats=1. Do not
        # report a frozen counter as a measured zero.
        if (schedstats != "on") {
            printf "# schedstats=%s: sched_count/sched_goidle/ttwu_* are n/a\n", (schedstats == "" ? "unknown" : schedstats)
            sum_sched = "n/a"
            sum_idle = "n/a"
            ttwu_c = "n/a"
            ttwu_l = "n/a"
            ttwu_r = "n/a"
        } else {
            ttwu_c = sum_ttwu
            ttwu_l = sum_ttwul
            ttwu_r = subint(sum_ttwu, sum_ttwul)
        }
        ttwu_frac = "n/a"
        if (is_num(ttwu_c) && is_num(ttwu_r) && (ttwu_c + 0) > 0)
            ttwu_frac = sprintf("%.4f", (ttwu_r + 0) / (ttwu_c + 0))
        printf "ttwu_count_delta=%s\n", ttwu_c
        printf "ttwu_local_delta=%s\n", ttwu_l
        printf "ttwu_remote_delta=%s\n", ttwu_r
        printf "ttwu_remote_frac=%s\n", ttwu_frac
        emit("ttwu_count_delta", ttwu_c)
        emit("ttwu_local_delta", ttwu_l)
        emit("ttwu_remote_delta", ttwu_r)
        emit("ttwu_remote_frac", ttwu_frac)
        printf "sched_count_delta=%s\n", sum_sched
        printf "sched_goidle_delta=%s\n", sum_idle
        printf "run_delay_ns_delta=%s\n", sum_delay
        printf "pcount_delta=%s\n", sum_pcount
        if (cmp(norm(sum_pcount) ~ /^-/ ? substr(norm(sum_pcount), 2) : norm(sum_pcount), "0") > 0 && norm(sum_pcount) !~ /^-/ && length(strip0(sum_delay)) <= 15 && length(strip0(sum_pcount)) <= 15 && norm(sum_delay) !~ /^-/) {
            rq = sprintf("%.0f", (sum_delay + 0) / (sum_pcount + 0))
        } else if (norm(sum_pcount) ~ /^-/ || norm(sum_delay) ~ /^-/) {
            rq = "n/a"
        } else if (norm(sum_pcount) == "0") {
            rq = "n/a"
        } else {
            rq = "n/a"
        }
        printf "rq_latency_ns=%s\n", rq
        print "# rq_latency_ns = run_delay_ns_delta / pcount_delta (average wait per timeslice)"
        emit("sched_count_delta", sum_sched)
        emit("sched_goidle_delta", sum_idle)
        emit("run_delay_ns_delta", sum_delay)
        emit("pcount_delta", sum_pcount)
        emit("rq_latency_ns", rq)
        exit 0
    }
    if (mode == "perf") {
        cycles = (("cycles" in perf) ? perf["cycles"] : "n/a")
        instr = (("instructions" in perf) ? perf["instructions"] : "n/a")
        cache_ref = (("cache-references" in perf) ? perf["cache-references"] : "n/a")
        cache_miss = (("cache-misses" in perf) ? perf["cache-misses"] : "n/a")
        llc = (("LLC-load-misses" in perf) ? perf["LLC-load-misses"] : "n/a")
        # Prefer architectural LLC-load-misses; fall back to PEBS / longest_lat.
        l3m = (("mem_load_retired.l3_miss" in perf) ? perf["mem_load_retired.l3_miss"] : "n/a")
        l3h = (("mem_load_retired.l3_hit" in perf) ? perf["mem_load_retired.l3_hit"] : "n/a")
        if (!is_num(llc) && ("longest_lat_cache.miss" in perf) && is_num(perf["longest_lat_cache.miss"]))
            llc = perf["longest_lat_cache.miss"]
        if (!is_num(llc) && is_num(l3m))
            llc = l3m
        csw = (("context-switches" in perf) ? perf["context-switches"] : "n/a")
        migr = (("cpu-migrations" in perf) ? perf["cpu-migrations"] : "n/a")
        ipc = "n/a"
        if (is_num(cycles) && is_num(instr) && (cycles + 0) > 0)
            ipc = sprintf("%.3f", (instr + 0) / (cycles + 0))
        mpki = "n/a"
        if (is_num(cache_miss) && is_num(instr) && (instr + 0) > 0)
            mpki = sprintf("%.3f", (cache_miss + 0) * 1000 / (instr + 0))
        miss_rate = "n/a"
        if (is_num(cache_miss) && is_num(cache_ref) && (cache_ref + 0) > 0)
            miss_rate = sprintf("%.4f", (cache_miss + 0) / (cache_ref + 0))
        llc_mpki = "n/a"
        if (is_num(llc) && is_num(instr) && (instr + 0) > 0)
            llc_mpki = sprintf("%.3f", (llc + 0) * 1000 / (instr + 0))
        dtlb = (("dTLB-load-misses" in perf) ? perf["dTLB-load-misses"] : "n/a")
        itlb = (("iTLB-load-misses" in perf) ? perf["iTLB-load-misses"] : "n/a")
        if (is_num(dtlb) && is_num(itlb) && dtlb !~ /\./ && itlb !~ /\./)
            tlb = addint(dtlb, itlb)
        else if (is_num(dtlb) && is_num(itlb))
            tlb = sprintf("%.0f", (dtlb + 0) + (itlb + 0))
        else if (is_num(dtlb))
            tlb = dtlb
        else if (is_num(itlb))
            tlb = itlb
        else
            tlb = "n/a"
        print "# perf stat values (empty or non-numeric events stored as n/a)"
        printf "cycles=%s\n", cycles
        printf "instructions=%s\n", instr
        printf "cache_references=%s\n", cache_ref
        printf "cache_misses=%s\n", cache_miss
        printf "llc_load_misses=%s\n", llc
        printf "dtlb_load_misses=%s\n", dtlb
        printf "itlb_load_misses=%s\n", itlb
        printf "tlb_misses=%s\n", tlb
        printf "l3_misses=%s\n", l3m
        printf "l3_hits=%s\n", l3h
        emit("cycles", cycles)
        emit("instructions", instr)
        emit("cache_references", cache_ref)
        emit("cache_misses", cache_miss)
        emit("llc_load_misses", llc)
        emit("dtlb_load_misses", dtlb)
        emit("itlb_load_misses", itlb)
        emit("tlb_misses", tlb)
        emit("l3_misses", l3m)
        emit("l3_hits", l3h)
        printf "context_switches=%s\n", csw
        printf "cpu_migrations=%s\n", migr
        printf "ipc=%s\n", ipc
        printf "cache_misses_per_kinstr=%s\n", mpki
        printf "cache_miss_rate=%s\n", miss_rate
        printf "llc_misses_per_kinstr=%s\n", llc_mpki
        emit("context_switches", csw)
        emit("cpu_migrations", migr)
        emit("ipc", ipc)
        emit("cache_misses_per_kinstr", mpki)
        emit("cache_miss_rate", miss_rate)
        emit("llc_misses_per_kinstr", llc_mpki)
        exit 0
    }
    if (mode == "table") {
        load_kv(ARGV[1], B)
        load_kv(ARGV[2], A)
        if (rows == "")
            rows = "wall_time_sec|wall time,cycles|cycles,instructions|instructions,cache_misses|cache-misses,llc_load_misses|LLC misses,tlb_misses|TLB misses,pgsteal_delta|pgsteal delta,compact_stall_delta|compact_stall delta"
        nrows = split(rows, R, ",")
        w = 22
        for (i = 1; i <= nrows; i++) {
            split(R[i], pair, "|")
            if (length(pair[2]) > w)
                w = length(pair[2])
        }
        nx = 0
        if (extra_prefix != "") {
            for (k in B)
                if (index(k, extra_prefix) == 1 && !(k in XS)) { XS[k] = 1; X[++nx] = k }
            for (k in A)
                if (index(k, extra_prefix) == 1 && !(k in XS)) { XS[k] = 1; X[++nx] = k }
            for (i = 1; i <= nx; i++)
                for (j = i + 1; j <= nx; j++)
                    if (X[j] < X[i]) { tmp = X[i]; X[i] = X[j]; X[j] = tmp }
            for (i = 1; i <= nx; i++)
                if (length(X[i]) > w)
                    w = length(X[i])
        }
        fmt = "%-" w "s %18s %18s %18s %12s\n"
        printf fmt, "metric", "before", "after", "delta", "delta%"
        for (i = 1; i <= nrows; i++) {
            split(R[i], pair, "|")
            key = pair[1]
            label = (pair[2] == "" ? key : pair[2])
            if (key in SHOWN)
                continue
            SHOWN[key] = 1
            # A workload-specific primary metric that neither run reported
            # (e.g. wl_* wake latency on the general workload) is not a row.
            if (extra_prefix != "" && index(key, extra_prefix) == 1 && !(key in B) && !(key in A))
                continue
            bv = kv_or_na(B, key)
            av = kv_or_na(A, key)
            dv = show_delta(bv, av)
            pv = pct(bv, av, dv)
            printf fmt, label, bv, av, dv, pv
        }
        for (i = 1; i <= nx; i++) {
            key = X[i]
            if (key in SHOWN)
                continue
            bv = kv_or_na(B, key)
            av = kv_or_na(A, key)
            if (key == extra_prefix "engine" || key == extra_prefix "args") {
                if (bv != av)
                    printf "WARNING %s differs: before=[%s] after=[%s]\n", key, bv, av
                continue
            }
            dv = show_delta(bv, av)
            pv = pct(bv, av, dv)
            printf fmt, key, bv, av, dv, pv
        }
        exit 0
    }
}
