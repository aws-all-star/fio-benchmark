# fio benchmark Tool
FIO(Flexible I/O Tester)를 활용한 포괄적인 성능 테스트 툴킷으로, 블록 장치와 파일 시스템을 벤치마킹합니다. 이 스크립트는 순차적인 읽기/쓰기 성능을 테스트하고, 최적의 워크로드 구성을 찾으며, 전체 이중 성능 분석을 수행하기 위한 자동화 스크립트를 포함합니다.
<br/><br/>

## 개요(Overview)
이 저장소에는 2 가지 주요 테스트 도구가 포함되어 있습니다:
- fs-test.sh: 자동 스케일업 단계가 포함된 파일 시스템 성능 테스트
- fio-gen-meta.sh: 메타데이터 집약적인 무작위 I/O 테스트
<br/><br/>

## 사전 준비(Pre-Requirement)
테스트를 실행하기 전에 다음 도구가 설치되어 있는지 확인하십시오:
- fio (Flexible I/O Tester) :
```sh
dnf -y install fio
```
- bc (Basic Calculator) :
```sh
dnf -y install bc
```
<br/>

## fs-test.sh - 파일시스템 성능 테스트
포괄적인 3단계 파일 시스템 성능 테스트를 실행하여 최대 처리량과 최적의 워크로드 구성을 식별합니다.

### 사용 방법
```sh
./fs-test.sh <디렉토리 명> <수행 시간(초)> <reader_jobs>
```
### 테스트 단계
fs-test.sh는 크게 3단계로 동작합니다.
|단계|내용|
--
|Phase1|Sequential Write Scale-Up: writer job 수를 늘리면서 최대 쓰기 성능 확인|
|Phase2|Sequential Read Scale-Up: reader job 수를 늘리면서 최대 읽기 성능 확인|
|Phase3|Full Duplex: reader는 고정하고 writer를 늘리면서 읽기 성능 저하 여부 확인|
