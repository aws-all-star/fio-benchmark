# fio benchmark Tool (IO 성능테스트 도구)
**FIO(Flexible I/O Tester)를 활용한 포괄적인 성능 테스트 툴킷**으로, 여러 스레드(Theard) 또는 프로세스(Process)를 생성하여 작업을 수행하여 블록 장치와 파일 시스템을 벤치마킹합니다. 이 스크립트는 **순차적인 읽기/쓰기 성능을 테스트하고, 최적의 워크로드 구성을 찾으며, 전체 이중 성능 분석을 수행하기 위한 자동화 스크립트**를 포함합니다.
<br/><br/>

# 적용 대상
대대수 Linux OS 에서 동작 가능하며, 대표적으로 Red Hat 계열에서 동작 테스트를 진행을 완료하였습니다.
- Red Hat Enterprise Linux 8 이상
- Rocky Linux 8 를 포함한 Oracle Linux 8, OpenSUSE 등
- Ubuntu 22.04 LTS 이상 지원
<br/><br/>

## 개요(Overview)
이 저장소에는 2 가지 주요 테스트 도구가 포함되어 있습니다:
- fs-test.sh: 자동 스케일업 단계가 포함된 파일 시스템 성능 테스트
- fio-gen-meta.sh: 메타데이터 집약적인 무작위 I/O 테스트 (Tech Priview)
<br/><br/>

## 사전 준비(Pre-Requirement)
아래 툴은 기본 레포지토리에서 제공합니다. 테스트를 실행하기 전에 다음 도구가 설치되어 있는지 확인하십시오:
- fio (Flexible I/O Tester) : fio는 디스크에 I/O 부하를 줘서 성능을 측정할 수 있는 도구
```sh
dnf -y install fio
```
- bc (Basic Calculator) : bc는 "Binary Calculator"의 줄임말로, 임의 정밀도 산술 연산을 수행하는 인터랙티브한 언어
```sh
dnf -y install bc
```
<br/><br/>

## fs-test.sh - 파일시스템 성능 테스트
포괄적인 3단계 파일 시스템 성능 테스트를 실행하여 최대 처리량과 최적의 워크로드 구성을 식별합니다.

## 사용 방법
```sh
./fs-test.sh <디렉토리 명> <수행 시간(초)> <reader_jobs>
```
**예시**
```sh
# ./fs-test.sh /testfs 30 8
==========================================
Test Directory: /xfs
Test Duration: 30s per test
Test Date: 20260510T104545

Phase 1: Sequential Write Scale-Up
------------------------------------
[Phase 1] Testing write baseline: jobs=1
[Phase 1] Baseline: 82 MiB/s
[Phase 1] Testing write: jobs=4
[Phase 1] Testing write: jobs=5
[Phase 1] Testing write: jobs=6
[Phase 1] Testing write: jobs=7
[Phase 1] Testing write: jobs=8
[Phase 1] Testing write: jobs=9
[Phase 1] Testing write: jobs=10
[Phase 1] Testing write: jobs=11
[Phase 1] Testing write: jobs=12
[Phase 1] Testing write: jobs=13
[Phase 1] Testing write: jobs=14
[Phase 1] Testing write: jobs=15
[Phase 1] Testing write: jobs=16
[Phase 1] Testing write: jobs=17
[Phase 1] Testing write: jobs=18
[Phase 1] Testing write: jobs=19
[Phase 1] Testing write: jobs=20
[Phase 1] Testing write: jobs=21
[Phase 1] Testing write: jobs=22
[Phase 1] Testing write: jobs=23
[Phase 1] Testing write: jobs=24
[Phase 1] Testing write: jobs=25
[Phase 1] Testing write: jobs=26
[Phase 1] Testing write: jobs=27
[Phase 1] Testing write: jobs=28
[Phase 1] Testing write: jobs=29
[Phase 1] Testing write: jobs=30
[Phase 1] Testing write: jobs=31
[Phase 1] Testing write: jobs=32
[Phase 1] Complete: Peak 1111 MiB/s with 15 jobs
```
<br/><br/>

## 테스트 단계
fs-test.sh는 크게 3단계로 동작합니다.
|단계|내용|
|---|---|
|Phase1|Sequential Write Scale-Up: writer job 수를 늘리면서 최대 쓰기 성능 확인|
|Phase2|Sequential Read Scale-Up: reader job 수를 늘리면서 최대 읽기 성능 확인|
|Phase3|Full Duplex: reader는 고정하고 writer를 늘리면서 읽기 성능 저하 여부 확인|

fs-test.sh는 fio_logs_fs_<timestamp>/ 로그 디렉터리와 임시 fio_test_<timestamp>/ 테스트 파일을 생성합니다. 
<br/><br/>

## 주요 기본값
|항목|기본값|
|---|---|
|Block size|1M|
|ioengine|libaio|
|iodepth|32|
|파일 크기|job당 10G|
|job 범위|4~32|
|O_DIRECT|기본 비활성화|

주의할 점은 공간이 꽤 필요합니다. 실행 예시에 따라 10G × max_jobs × test phases 수준의 충분한 공간을 필요로 할 수 있습니다. <br/>
현재 원본 기준 FILE_SIZE=10G, MAX_JOBS=32라면 read 준비파일만 최대 320GB가 필요하므로 테스트 환경에 따라 해당 값을 변경하는 것을 추천합니다.
<br/><br/>

## 결과 확인
실행 후 아래 형태의 로그 디렉터리가 생성됩니다.
```sh
ls -ltr
ls fio_logs_fs_*
```
