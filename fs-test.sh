#!/bin/bash
# Created by Donghyun Kim
# Date: 09 MAY 2026
# KT DS DX Tech Team, Infra Architecture(Meister)
#
# Usage: ./fs-test.sh <test_directory> <duration> <reader_jobs>
#
# Runs a 3-phase filesystem performance test:
#   Phase 1: Write scale-up (find peak write throughput)
#   Phase 2: Read scale-up (find peak read throughput)
#   Phase 3: Full duplex with fixed readers at 400MB/s rate limit,
#            scale writers until max write throughput or readers drop below 365MB/s
#
# Examples:
#   ./fs-test.sh /mnt/testfs 30 8
#   ./fs-test.sh /data/perf 60 16

set -euo pipefail

# Check if fio is installed
command -v fio >/dev/null || { echo "ERROR: fio not in PATH, try \"dnf install fio\" or \"brew install fio\""; exit 1; }
command -v bc >/dev/null || { echo "ERROR: bc not in PATH, try \"dnf install bc\" or \"brew install bc\""; exit 1; }

# Parse command-line arguments
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <test_directory> <duration_seconds> <reader_jobs>"
    echo ""
    echo "Examples:"
    echo "  $0 /mnt/testfs 30 8"
    echo "  $0 /data/perf 60 16"
    exit 1
fi

TEST_DIR="$1"
DURATION="$2"
READER_JOBS="$3"

# Validate inputs
if ! [[ $DURATION =~ ^[0-9]+$ ]]; then
    echo "ERROR: duration must be an integer (seconds)"
    exit 1
fi

if ! [[ $READER_JOBS =~ ^[0-9]+$ ]] || [ $READER_JOBS -lt 1 ]; then
    echo "ERROR: reader_jobs must be a positive integer"
    exit 1
fi

if [ ! -d "$TEST_DIR" ]; then
    echo "ERROR: $TEST_DIR is not a valid directory"
    exit 1
fi

# Check if directory is writable
if [ ! -w "$TEST_DIR" ]; then
    echo "ERROR: $TEST_DIR is not writable"
    exit 1
fi

# Configuration
USE_DIRECT=0  # Set to 0 to disable O_DIRECT (for filesystems that don't support it)
FORCE_MAX_JOBS=1  # Set to 1 to force testing all job counts up to MAX_JOBS (disable early break-out)
BLOCK_SIZE="1M"
IO_ENGINE="libaio"
IO_DEPTH=32
FILE_SIZE="10G"
START_JOBS=4
MAX_JOBS=32
TEST_DATE=$(date '+%Y%m%dT%H%M%S')
HOST=$(hostname -s)
LOG_DIR="./fio_logs_fs_${TEST_DATE}"
TEST_FILES_DIR="${TEST_DIR}/fio_test_${TEST_DATE}"

# Create log directory
mkdir -p "$LOG_DIR"

# Create test files directory
mkdir -p "$TEST_FILES_DIR"

# Main log file (detailed output)
MAIN_LOG="${LOG_DIR}/fs-test-${HOST}.log"

# Record start time
TEST_START_TIME=$(date +%s)

# Function to log to file and optionally to stderr
log() {
    echo "$@" >> "$MAIN_LOG"
}

log_err() {
    echo "$@" | tee -a "$MAIN_LOG" >&2
}

# Cleanup function
cleanup() {
    log "Cleaning up test files..."
    rm -rf "$TEST_FILES_DIR"
    log "Cleanup complete"
}

# Register cleanup on exit
trap cleanup EXIT

# Function to parse fio output and extract bandwidth in MiB/s
parse_bandwidth() {
    local output="$1"
    local type="$2"  # "WRITE" or "READ"
    
    local perf_line=$(echo "$output" | grep -Eo "${type}: bw=[0-9.]+[KMGT]?i?B/s" | head -1)
    
    if [[ "$perf_line" =~ bw=([0-9.]+)([KMGT]?i?B)/s ]]; then
        local perf_val=${BASH_REMATCH[1]}
        local unit=${BASH_REMATCH[2]}
        
        case "$unit" in
            KiB)
                echo "scale=2; $perf_val / 1024" | bc
                ;;
            MiB)
                echo "$perf_val"
                ;;
            GiB)
                echo "scale=2; $perf_val * 1024" | bc
                ;;
            TiB)
                echo "scale=2; $perf_val * 1024 * 1024" | bc
                ;;
            *)
                echo "0"
                ;;
        esac
    else
        echo "0"
    fi
}

# Function to run fio sequential write test
run_write_test() {
    local num_jobs="$1"
    local output_file="${LOG_DIR}/write_${num_jobs}jobs.txt"
    
    log "Running write test with $num_jobs jobs..."
    
    # Generate file list
    local file_list=""
    for i in $(seq 1 "$num_jobs"); do
        file_list="${file_list}:${TEST_FILES_DIR}/testfile_write_${i}.dat"
    done
    file_list="${file_list:1}"  # Remove leading colon
    
    fio --name=seqwrite \
        --filename="$file_list" \
        --rw=write \
        --bs="$BLOCK_SIZE" \
        --ioengine="$IO_ENGINE" \
        --iodepth="$IO_DEPTH" \
        --numjobs="$num_jobs" \
        --runtime="$DURATION" \
        --time_based \
        --direct=$USE_DIRECT \
        --size="$FILE_SIZE" \
        --group_reporting \
        >"$output_file" 2>&1
    
    cat "$output_file" >> "$MAIN_LOG"
    
    local bw=$(parse_bandwidth "$(cat "$output_file")" "WRITE")
    echo "$bw"
}

# Function to run fio sequential read test
run_read_test() {
    local num_jobs="$1"
    local output_file="${LOG_DIR}/read_${num_jobs}jobs.txt"
    
    log "Running read test with $num_jobs jobs..."
    
    # Drop caches if O_DIRECT is disabled
    if [ $USE_DIRECT -eq 0 ]; then
        sync
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        log "Dropped caches (O_DIRECT disabled)"
    fi
    
    # Generate file list
    local file_list=""
    for i in $(seq 1 "$num_jobs"); do
        file_list="${file_list}:${TEST_FILES_DIR}/testfile_read_${i}.dat"
    done
    file_list="${file_list:1}"  # Remove leading colon
    
    fio --name=seqread \
        --filename="$file_list" \
        --rw=read \
        --bs="$BLOCK_SIZE" \
        --ioengine="$IO_ENGINE" \
        --iodepth="$IO_DEPTH" \
        --numjobs="$num_jobs" \
        --runtime="$DURATION" \
        --time_based \
        --direct=$USE_DIRECT \
        --size="$FILE_SIZE" \
        --group_reporting \
        >"$output_file" 2>&1
    
    cat "$output_file" >> "$MAIN_LOG"
    
    local bw=$(parse_bandwidth "$(cat "$output_file")" "READ")
    echo "$bw"
}

# Function to run full duplex test with per-job reader stats
run_fdx_test() {
    local write_jobs="$1"
    local read_jobs="$2"
    local output_file="${LOG_DIR}/fdx_w${write_jobs}_r${read_jobs}.txt"
    
    log "Running full duplex test with $write_jobs write jobs and $read_jobs read jobs (rate-limited to 400MB/s each)..."
    
    # Drop caches if O_DIRECT is disabled
    if [ $USE_DIRECT -eq 0 ]; then
        sync
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        log "Dropped caches (O_DIRECT disabled)"
    fi
    
    # Generate write file list
    local write_file_list=""
    for i in $(seq 1 "$write_jobs"); do
        write_file_list="${write_file_list}:${TEST_FILES_DIR}/testfile_fdx_write_${i}.dat"
    done
    write_file_list="${write_file_list:1}"  # Remove leading colon
    
    # Generate read file list
    local read_file_list=""
    for i in $(seq 1 "$read_jobs"); do
        read_file_list="${read_file_list}:${TEST_FILES_DIR}/testfile_fdx_read_${i}.dat"
    done
    read_file_list="${read_file_list:1}"  # Remove leading colon
    
    # Run without group_reporting for readers to get per-job stats
    fio --name=fdx_write \
        --filename="$write_file_list" \
        --rw=write \
        --bs="$BLOCK_SIZE" \
        --ioengine="$IO_ENGINE" \
        --iodepth="$IO_DEPTH" \
        --numjobs="$write_jobs" \
        --runtime="$DURATION" \
        --time_based \
        --direct=$USE_DIRECT \
        --size="$FILE_SIZE" \
        --group_reporting \
        --new_group \
        --name=fdx_read \
        --filename="$read_file_list" \
        --rw=read \
        --bs="$BLOCK_SIZE" \
        --ioengine="$IO_ENGINE" \
        --iodepth="$IO_DEPTH" \
        --numjobs="$read_jobs" \
        --runtime="$DURATION" \
        --time_based \
        --direct=$USE_DIRECT \
        --size="$FILE_SIZE" \
        --rate=400m \
        >"$output_file" 2>&1
    
    cat "$output_file" >> "$MAIN_LOG"
    
    # Parse write bandwidth (grouped)
    local write_bw=$(parse_bandwidth "$(cat "$output_file")" "WRITE")
    
    # Parse individual read job bandwidths
    local read_bws=()
    local min_read_bw=999999
    local total_read_bw=0
    local job_num=0
    
    # Extract per-job read bandwidth
    # Strategy 1: Look for per-job lines in fdx_read section (format: "  fdx_read.X.0")
    while IFS= read -r line; do
        if [[ "$line" =~ fdx_read\.[0-9]+\.[0-9]+.*read:.*bw=([0-9.]+)([KMGT]?i?B)/s ]]; then
            local perf_val=${BASH_REMATCH[1]}
            local unit=${BASH_REMATCH[2]}
            
            local bw_mib=0
            case "$unit" in
                KiB)
                    bw_mib=$(echo "scale=2; $perf_val / 1024" | bc)
                    ;;
                MiB)
                    bw_mib=$perf_val
                    ;;
                GiB)
                    bw_mib=$(echo "scale=2; $perf_val * 1024" | bc)
                    ;;
                TiB)
                    bw_mib=$(echo "scale=2; $perf_val * 1024 * 1024" | bc)
                    ;;
            esac
            
            read_bws+=("$bw_mib")
            total_read_bw=$(echo "scale=2; $total_read_bw + $bw_mib" | bc)
            
            if (( $(echo "$bw_mib < $min_read_bw" | bc -l) )); then
                min_read_bw=$bw_mib
            fi
            
            job_num=$((job_num + 1))
        fi
    done < "$output_file"
    
    # Strategy 2: If no per-job stats found, look for "read:" lines after fdx_read job header
    if [ $job_num -eq 0 ]; then
        local in_read_jobs=0
        while IFS= read -r line; do
            # Detect start of fdx_read jobs section
            if [[ "$line" =~ ^fdx_read: ]]; then
                in_read_jobs=1
                continue
            fi
            
            # Stop at next major section (Run status, disk stats, etc)
            if [ $in_read_jobs -eq 1 ] && [[ "$line" =~ ^(Run status|Disk stats): ]]; then
                break
            fi
            
            # Capture individual read job stats
            if [ $in_read_jobs -eq 1 ] && [[ "$line" =~ ^[[:space:]]+read:.*bw=([0-9.]+)([KMGT]?i?B)/s ]]; then
                local perf_val=${BASH_REMATCH[1]}
                local unit=${BASH_REMATCH[2]}
                
                local bw_mib=0
                case "$unit" in
                    KiB)
                        bw_mib=$(echo "scale=2; $perf_val / 1024" | bc)
                        ;;
                    MiB)
                        bw_mib=$perf_val
                        ;;
                    GiB)
                        bw_mib=$(echo "scale=2; $perf_val * 1024" | bc)
                        ;;
                    TiB)
                        bw_mib=$(echo "scale=2; $perf_val * 1024 * 1024" | bc)
                        ;;
                esac
                
                read_bws+=("$bw_mib")
                total_read_bw=$(echo "scale=2; $total_read_bw + $bw_mib" | bc)
                
                if (( $(echo "$bw_mib < $min_read_bw" | bc -l) )); then
                    min_read_bw=$bw_mib
                fi
                
                job_num=$((job_num + 1))
            fi
        done < "$output_file"
    fi
    
    # If we still didn't find enough per-job stats, use average as fallback
    if [ $job_num -lt $read_jobs ]; then
        log "WARNING: Only found $job_num per-job read stats, expected $read_jobs"
        log "Using average as fallback"
        total_read_bw=$(parse_bandwidth "$(cat "$output_file")" "READ")
        local avg_read_bw=$(echo "scale=2; $total_read_bw / $read_jobs" | bc)
        min_read_bw=$avg_read_bw
        log "Fallback average: ${avg_read_bw} MiB/s per reader"
    fi
    
    local avg_read_bw=$(echo "scale=2; $total_read_bw / $read_jobs" | bc)
    
    echo "${write_bw}:${total_read_bw}:${avg_read_bw}:${min_read_bw}"
}

# Main test execution
log "=========================================="
log "FILESYSTEM PERFORMANCE TEST"
log "=========================================="
log "Invocation: $0 $TEST_DIR $DURATION $READER_JOBS"
log "Test Directory: $TEST_DIR"
log "Test Files Directory: $TEST_FILES_DIR"
log "Test Date: $TEST_DATE"
log "Duration per test: ${DURATION}s"
log "O_DIRECT: $([ $USE_DIRECT -eq 1 ] && echo 'enabled' || echo 'disabled')"
log "Log Directory: $LOG_DIR"
log ""

echo "=========================================="
echo "FILESYSTEM PERFORMANCE TEST"
echo "=========================================="
echo "Test Directory: $TEST_DIR"
echo "Test Duration: ${DURATION}s per test"
echo "Test Date: $TEST_DATE"
echo ""

# Phase 1: Sequential Write Scale-Up
log ""
log "=========================================="
log "PHASE 1: Sequential Write Scale-Up"
log "=========================================="
log "Test Directory: $TEST_DIR"
log "Test Date: $TEST_DATE"
log "Duration per test: ${DURATION}s"
log ""

echo "Phase 1: Sequential Write Scale-Up"
echo "------------------------------------"

# Run baseline single job test first
echo "[Phase 1] Testing write baseline: jobs=1"
log "Running baseline single job write test..."
sync
single_write_perf=$(run_write_test 1)
log "Write jobs=1 (baseline): ${single_write_perf} MiB/s"
log ""
echo "[Phase 1] Baseline: $(printf "%.0f" "$single_write_perf") MiB/s"

max_write_perf=$single_write_perf
optimal_write_jobs=1
prev_write_perf=$single_write_perf
jobs=$START_JOBS

while [ $jobs -le $MAX_JOBS ]; do
    echo "[Phase 1] Testing write: jobs=$jobs"
    sync
    
    write_bw=$(run_write_test "$jobs")
    write_bw_int=$(printf "%.0f" "$write_bw")
    
    log "Write jobs=$jobs: ${write_bw} MiB/s"
    
    if (( $(echo "$write_bw > $max_write_perf" | bc -l) )); then
        max_write_perf=$write_bw
        optimal_write_jobs=$jobs
    fi
    
    # Stop if performance increase is not more than 1% from previous (unless FORCE_MAX_JOBS is set)
    if [ $FORCE_MAX_JOBS -eq 0 ] && (( $(echo "$prev_write_perf > 0" | bc -l) )); then
        increase=$(echo "scale=2; ($write_bw - $prev_write_perf) / $prev_write_perf * 100" | bc)
        if (( $(echo "$increase <= 1" | bc -l) )); then
            log "Performance increase only ${increase}% (not more than 1%), stopping scale-up"
            break
        fi
    fi
    
    prev_write_perf=$write_bw
    jobs=$((jobs + 1))
done

log ""
log "Phase 1 Complete: Optimal write performance: ${max_write_perf} MiB/s with ${optimal_write_jobs} jobs"
echo "[Phase 1] Complete: Peak $(printf "%.0f" "$max_write_perf") MiB/s with $optimal_write_jobs jobs"
echo ""

# Phase 2: Sequential Read Scale-Up
log ""
log "=========================================="
log "PHASE 2: Sequential Read Scale-Up"
log "=========================================="
log ""

echo "Phase 2: Sequential Read Scale-Up"
echo "----------------------------------"

# Pre-create files for read tests
echo "[Phase 2] Preparing test files for read tests..."
log "Pre-creating test files for read tests..."
for i in $(seq 1 "$MAX_JOBS"); do
    fio --name=prep \
        --filename="${TEST_FILES_DIR}/testfile_read_${i}.dat" \
        --rw=write \
        --bs="$BLOCK_SIZE" \
        --ioengine="$IO_ENGINE" \
        --iodepth="$IO_DEPTH" \
        --size="$FILE_SIZE" \
        --direct=$USE_DIRECT \
        >/dev/null 2>&1
done
log "Test files created"
sync

# Run baseline single job test first
echo "[Phase 2] Testing read baseline: jobs=1"
log "Running baseline single job read test..."
sync
single_read_perf=$(run_read_test 1)
log "Read jobs=1 (baseline): ${single_read_perf} MiB/s"
log ""
echo "[Phase 2] Baseline: $(printf "%.0f" "$single_read_perf") MiB/s"

max_read_perf=$single_read_perf
optimal_read_jobs=1
prev_read_perf=$single_read_perf
jobs=$START_JOBS

while [ $jobs -le $MAX_JOBS ]; do
    echo "[Phase 2] Testing read: jobs=$jobs"
    sync
    
    read_bw=$(run_read_test "$jobs")
    read_bw_int=$(printf "%.0f" "$read_bw")
    
    log "Read jobs=$jobs: ${read_bw} MiB/s"
    
    if (( $(echo "$read_bw > $max_read_perf" | bc -l) )); then
        max_read_perf=$read_bw
        optimal_read_jobs=$jobs
    fi
    
    # Stop if performance increase is not more than 1% from previous (unless FORCE_MAX_JOBS is set)
    if [ $FORCE_MAX_JOBS -eq 0 ] && (( $(echo "$prev_read_perf > 0" | bc -l) )); then
        increase=$(echo "scale=2; ($read_bw - $prev_read_perf) / $prev_read_perf * 100" | bc)
        if (( $(echo "$increase <= 1" | bc -l) )); then
            log "Performance increase only ${increase}% (not more than 1%), stopping scale-up"
            break
        fi
    fi
    
    prev_read_perf=$read_bw
    jobs=$((jobs + 1))
done

log ""
log "Phase 2 Complete: Optimal read performance: ${max_read_perf} MiB/s with ${optimal_read_jobs} jobs"
echo "[Phase 2] Complete: Peak $(printf "%.0f" "$max_read_perf") MiB/s with $optimal_read_jobs jobs"
echo ""

# Phase 3: Full Duplex Test with Fixed Readers
log ""
log "=========================================="
log "PHASE 3: Full Duplex Test"
log "=========================================="
log "Fixed read jobs (rate-limited to 400 MB/s each, target min 365 MB/s per reader)"
log "Scaling write jobs to find maximum write throughput"
log ""

echo "Phase 3: Full Duplex Test"
echo "-------------------------"
echo "Strategy: Fixed readers at 400MB/s rate limit"
echo "          Scale writers until max throughput or readers drop below 365MB/s"
echo ""

TARGET_MIN_READ=365
RATE_LIMIT=400

# Pre-create files for full duplex tests
echo "[Phase 3] Preparing test files for full duplex tests..."
log "Pre-creating test files for full duplex tests..."

# Create read files
for i in $(seq 1 32); do
    fio --name=prep \
        --filename="${TEST_FILES_DIR}/testfile_fdx_read_${i}.dat" \
        --rw=write \
        --bs="$BLOCK_SIZE" \
        --ioengine="$IO_ENGINE" \
        --iodepth="$IO_DEPTH" \
        --size="$FILE_SIZE" \
        --direct=$USE_DIRECT \
        >/dev/null 2>&1
done
log "Full duplex test files created"
sync

# Use the reader count from command-line arguments
read_jobs=$READER_JOBS
max_writers=0
max_write_perf=0
max_total_read_perf=0
max_avg_read=0
max_min_read=0

log "Testing with ${read_jobs} fixed read jobs..."
echo "[Phase 3] Fixed readers: $read_jobs (rate-limited to ${RATE_LIMIT}MB/s each)"
echo "[Phase 3] Minimum acceptable read performance: ${TARGET_MIN_READ}MB/s per reader"
echo ""

# Scale up writers from 1 to 32
for write_jobs in $(seq 1 32); do
    echo "[Phase 3] Testing FDX: writers=$write_jobs, readers=$read_jobs"
    
    # Drop caches before test
    sync
    
    result=$(run_fdx_test "$write_jobs" "$read_jobs")
    write_bw=$(echo "$result" | cut -d: -f1)
    total_read_bw=$(echo "$result" | cut -d: -f2)
    avg_read_bw=$(echo "$result" | cut -d: -f3)
    min_read_bw=$(echo "$result" | cut -d: -f4)
    
    log "Writers=$write_jobs: write=${write_bw} MiB/s, total_read=${total_read_bw} MiB/s, avg_read=${avg_read_bw} MiB/s, min_read=${min_read_bw} MiB/s"
    
    # Check if minimum reader still meets threshold
    if (( $(echo "$min_read_bw >= $TARGET_MIN_READ" | bc -l) )); then
        max_writers=$write_jobs
        max_write_perf=$write_bw
        max_total_read_perf=$total_read_bw
        max_avg_read=$avg_read_bw
        max_min_read=$min_read_bw
        echo "  ✓ Writers=$write_jobs: write=$(printf "%.0f" "$write_bw") MiB/s, min_read=$(printf "%.0f" "$min_read_bw") MiB/s"
        log "Valid config: $write_jobs writers maintain minimum read performance (min=${min_read_bw} MiB/s)"
    else
        echo "  ✗ Writers=$write_jobs: min_read=$(printf "%.0f" "$min_read_bw") MiB/s (below ${TARGET_MIN_READ} MiB/s threshold)"
        log "Writers=$write_jobs caused read performance to drop below ${TARGET_MIN_READ} MiB/s (min=${min_read_bw} MiB/s), stopping"
        break
    fi
done

log ""
log "Phase 3 Complete"
echo ""
echo "[Phase 3] Complete"
echo ""

# Calculate total test time
TEST_END_TIME=$(date +%s)
TOTAL_TEST_TIME=$((TEST_END_TIME - TEST_START_TIME))
TEST_HOURS=$((TOTAL_TEST_TIME / 3600))
TEST_MINUTES=$(((TOTAL_TEST_TIME % 3600) / 60))
TEST_SECONDS=$((TOTAL_TEST_TIME % 60))

# Final results summary
log ""
log "=========================================="
log "FINAL RESULTS SUMMARY"
log "=========================================="
log "Invocation: $0 $TEST_DIR $DURATION $READER_JOBS"
log "Test Directory: $TEST_DIR"
log "Test Duration: ${DURATION}s per test"
log "Test Date: $TEST_DATE"
log "Total Test Time: ${TEST_HOURS}h ${TEST_MINUTES}m ${TEST_SECONDS}s"
log ""
log "Phase 1 - Sequential Write Scale-Up:"
log "  Single Job Performance: $(printf "%.0f" "$single_write_perf") MiB/s"
log "  Peak Performance: $(printf "%.0f" "$max_write_perf") MiB/s"
log "  Optimal Jobs: $optimal_write_jobs"
log ""
log "Phase 2 - Sequential Read Scale-Up:"
log "  Single Job Performance: $(printf "%.0f" "$single_read_perf") MiB/s"
log "  Peak Performance: $(printf "%.0f" "$max_read_perf") MiB/s"
log "  Optimal Jobs: $optimal_read_jobs"
log ""
log "Phase 3 - Full Duplex (Write + Rate-Limited Read):"
if [ $max_writers -gt 0 ]; then
    log "  Fixed Read Jobs: $read_jobs (rate-limited to ${RATE_LIMIT} MB/s each)"
    log "  Maximum Write Jobs: $max_writers"
    log "  Write Performance: $(printf "%.0f" "$max_write_perf") MiB/s"
    log "  Total Read Performance: $(printf "%.0f" "$max_total_read_perf") MiB/s"
    log "  Average Read per Job: $(printf "%.0f" "$max_avg_read") MiB/s"
    log "  Minimum Read per Job: $(printf "%.0f" "$max_min_read") MiB/s"
    log "  Status: All readers maintain minimum threshold (${TARGET_MIN_READ} MiB/s)"
else
    log "  No configuration found - even 1 writer causes read performance degradation"
fi
log "=========================================="
log ""

# Output final results to stdout
echo "=========================================="
echo "FILESYSTEM PERFORMANCE TEST RESULTS"
echo "=========================================="
echo "Test Directory: $TEST_DIR"
echo "Test Duration: ${DURATION}s per test"
echo "Test Date: $TEST_DATE"
echo "Total Test Time: ${TEST_HOURS}h ${TEST_MINUTES}m ${TEST_SECONDS}s"
echo ""
echo "Phase 1 - Sequential Write Scale-Up:"
echo "  Single Job Performance: $(printf "%.0f" "$single_write_perf") MiB/s"
echo "  Peak Performance: $(printf "%.0f" "$max_write_perf") MiB/s"
echo "  Optimal Jobs: $optimal_write_jobs"
echo ""
echo "Phase 2 - Sequential Read Scale-Up:"
echo "  Single Job Performance: $(printf "%.0f" "$single_read_perf") MiB/s"
echo "  Peak Performance: $(printf "%.0f" "$max_read_perf") MiB/s"
echo "  Optimal Jobs: $optimal_read_jobs"
echo ""
echo "Phase 3 - Full Duplex (Write + Rate-Limited Read):"
if [ $max_writers -gt 0 ]; then
    echo "  Configuration:"
    echo "    Fixed Read Jobs: $read_jobs (rate-limited to ${RATE_LIMIT} MB/s each)"
    echo "    Maximum Write Jobs: $max_writers"
    echo ""
    echo "  Results:"
    echo "    Write Performance: $(printf "%.0f" "$max_write_perf") MiB/s"
    echo "    Total Read Performance: $(printf "%.0f" "$max_total_read_perf") MiB/s"
    echo "    Average Read per Job: $(printf "%.0f" "$max_avg_read") MiB/s"
    echo "    Minimum Read per Job: $(printf "%.0f" "$max_min_read") MiB/s"
    echo ""
    echo "    Status: ✓ All readers maintain minimum threshold (${TARGET_MIN_READ} MiB/s)"
else
    echo "  Status: ✗ No configuration found - even 1 writer causes read performance degradation"
fi
echo ""
echo "Detailed logs: $LOG_DIR"
echo "Main log: $MAIN_LOG"
echo "=========================================="
