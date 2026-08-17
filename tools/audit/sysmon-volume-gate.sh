#!/bin/bash
# Runs ON so01. THE PLAN'S ACTUAL STEP 3 GATE, which was only half-verified.
#
# Plan text: "Gate: Sysmon event IDs 1, 3, 10, 11, 22 all present in ES; volume within
# 5,000-10,000/endpoint/day." Task #38 marked Step 3 done on the CONFIG FINGERPRINT alone (sysmon-modular
# confirmed by ruleset hash) - the event-ID and volume halves were never measured. Measuring both now.
#
# Also re-checks the Step 1 gate (">= 5,000 Windows events/host/day"), because my own audit showed
# ws01 3,430 / ws02 3,676 / sql01 2,847 / fs01 2,655 per 24h - which are BELOW that threshold. If so,
# Step 1 is not actually passing either and the prompt's "Steps 1 and 2 DONE" needs qualifying.
set -o pipefail
S() { echo ${SO_PASSWORD} | sudo -S "$@" 2>/dev/null; }
Q() { S curl -sSk -K /opt/so/conf/elasticsearch/curl.config "https://localhost:9200/$1" \
        -H 'Content-Type: application/json' -d "$2"; }

echo "== Sysmon event IDs over 24h (gate: 1,3,10,11,22 all present) =="
for id in 1 3 10 11 22 7 8 12 13 15 17 23 25; do
  n=$(Q "logs-*/_search?size=0" "{\"track_total_hits\":true,\"query\":{\"bool\":{\"filter\":[
      {\"term\":{\"event.dataset\":\"windows.sysmon_operational\"}},{\"term\":{\"event.code\":\"$id\"}},
      {\"range\":{\"@timestamp\":{\"gte\":\"now-24h\"}}}]}}}" \
     | python3 -c "import sys,json;print(json.load(sys.stdin)['hits']['total']['value'])" 2>/dev/null)
  case $id in
    1) lbl="process creation";; 3) lbl="network connection";; 10) lbl="process access (cred theft)";;
    11) lbl="file create";; 22) lbl="DNS query";; 7) lbl="image load";; 8) lbl="remote thread";;
    12|13) lbl="registry";; 15) lbl="file stream";; 17) lbl="named pipe";; 23) lbl="file delete";;
    25) lbl="process tampering";; *) lbl="";; esac
  printf "   EID %-3s %-28s %8s\n" "$id" "$lbl" "${n:-ERR}"
done

echo
echo "== Sysmon volume PER ENDPOINT over 24h (gate: 5,000-10,000/endpoint/day) =="
Q "logs-*/_search?size=0" '{"query":{"bool":{"filter":[
    {"term":{"event.dataset":"windows.sysmon_operational"}},
    {"range":{"@timestamp":{"gte":"now-24h"}}}]}},
  "aggs":{"h":{"terms":{"field":"host.name","size":10}}}}' \
 | python3 -c "
import sys,json
bs=json.load(sys.stdin).get('aggregations',{}).get('h',{}).get('buckets',[])
if not bs: print('   NO sysmon docs at all')
inband=0
for b in bs:
    n=b['doc_count']
    flag='IN BAND' if 5000<=n<=10000 else ('BELOW' if n<5000 else 'ABOVE')
    if 5000<=n<=10000: inband+=1
    print('   %-12s %8s  %s' % (b['key'], format(n,','), flag))
print('   endpoints in the 5,000-10,000 band: %d of %d' % (inband, len(bs)))"  2>/dev/null

echo
echo "== ALL Windows events per host over 24h (the Step 1 gate: >=5,000/host/day) =="
Q "logs-*/_search?size=0" '{"query":{"bool":{"filter":[
    {"terms":{"event.module":["windows","system"]}},
    {"range":{"@timestamp":{"gte":"now-24h"}}}]}},
  "aggs":{"h":{"terms":{"field":"host.name","size":12}}}}' \
 | python3 -c "
import sys,json
bs=json.load(sys.stdin).get('aggregations',{}).get('h',{}).get('buckets',[])
ok=0; tot=0
for b in bs:
    n=b['doc_count']
    if b['key'] in ('so01','cthost01','cthuwu'): continue   # not Windows guests
    tot+=1
    if n>=5000: ok+=1
    print('   %-12s %8s  %s' % (b['key'], format(n,','), 'PASS' if n>=5000 else 'BELOW 5k'))
print('   Windows guests at or above 5,000/day: %d of %d' % (ok, tot))"  2>/dev/null

echo
echo "== which Sysmon config is loaded? (effective state, by ruleset) =="
Q "logs-*/_search?size=1" '{"query":{"bool":{"filter":[
    {"term":{"event.dataset":"windows.sysmon_operational"}},{"term":{"event.code":"16"}},
    {"range":{"@timestamp":{"gte":"now-30d"}}}]}},"sort":[{"@timestamp":"desc"}]}' \
 | python3 -c "
import sys,json
hs=json.load(sys.stdin).get('hits',{}).get('hits',[])
if not hs: print('   no EID 16 (config change) events in 30d - config predates ingestion')
for h in hs:
    ed=h['_source'].get('winlog',{}).get('event_data',{})
    print('   %s  config=%s hash=%s' % (h['_source'].get('@timestamp'),
          ed.get('ConfigurationFileHash','?'), ed.get('Configuration','?')))" 2>/dev/null
