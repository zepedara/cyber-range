# Reference Environment Snapshot

**Generated:** 2026-08-18T23:45:10Z by `tools/access/publish-snapshot.sh` (read-only).

This is a sanitized point-in-time capture of the **reference** cyber range, published so a
remote builder can consult the estate WITHOUT needing live access to the private network.
House LAN and tailnet addressing are redacted; range-internal `10.x` addressing is kept
deliberately, because it is the part that is useful.

**Regenerate with:** `ssh <hypervisor> 'bash -s' < tools/access/publish-snapshot.sh > docs/ENVIRONMENT_SNAPSHOT.md`

If this snapshot answers your question, you do not need live access. See
`tools/access/README.md` for the escalation path if it does not.

---

## Hypervisor
```
pve-manager/8.4.19/a68fb383814bb1e6 (running kernel: 6.8.12-39-pve)
6.8.12-39-pve
CPU(s): 48
Model name: AMD Ryzen Threadripper 3960X 24-Core Processor
Thread(s) per core: 2
Core(s) per socket: 24
Socket(s): 1
CPU(s) scaling MHz: 89%
RAM: total=125G used=94G available=31G
```

## Guests
```
      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID       
       100 rick                 running    6144            1863.02 3145750   
       101 flare-vm             stopped    8192             120.00 0         
       102 velociraptor01       stopped    8192              60.00 0         
       130 sandbox01            stopped    4096              21.50 0         
       140 soc-wazuh            stopped    8192              43.50 0         
       141 dfir-ws              stopped    8192              62.20 0         
       142 remnux               stopped    8192             100.00 0         
       143 sift-ws              stopped    8192              80.00 0         
       146 kali                 running    4096              45.00 138919    
       150 range-dc01           running    6144              60.00 2423670   
       151 range-FS01           running    6144              60.00 2444106   
       152 range-SQL01          running    6144              60.00 2444520   
       153 range-WEB01          running    6144              60.00 2444994   
       154 range-WS01           running    4096              60.00 2445270   
       155 range-WS02           running    4096              60.00 2445692   
       160 range-linux-web      stopped    4096              21.50 0         
       161 ghosts01             running    6144              33.50 2931171   
       170 so01                 running    40960            300.00 647922    
       200 golden-desktop       stopped    6144              23.50 0         
       210 redinfra01           stopped    6144              33.50 0         
       300 fw01                 running    4096              32.00 1860308   
       310 cthost01             running    24576            200.00 1852647   
      3010 irtest-win10ent      stopped    8192              64.00 0         
      3011 irtest-win11ent      stopped    8192              64.00 0         
      3012 irtest-ubuntu        stopped    4096              27.50 0         
      3013 irtest-rocky9        stopped    4096              34.00 0         
      3020 relics-vm            stopped    12288            119.50 0         
      9000 ubuntu-noble-tmpl    stopped    2048               3.50 0         
      9001 ubuntu-jammy-tmpl    stopped    2048               2.20 0         
```

## Bridges
```
vmbr0      UP
vmbr20     UNKNOWN
vmbr60     UP
vmbr30     DOWN
vmbr61     UP
vmbr40     UP
vmbr91     UP
vmbr50     UNKNOWN
vmbr59     UNKNOWN
vmbr90     DOWN
vmbr1      UP
```

## SPAN bridge discipline (load-bearing - see AUDIT_AND_LESSONS 4.2)
```
vmbr91 ageing_time=0
port spanmir-br learning=0
port tap170i1 learning=0
port tap310i2 learning=0
```

## Storage
```
Name           Type     Status           Total            Used       Available        %
hot             dir     active      3844550452      2744304544      1061159352   71.38%
local           dir     active       164029204        96081484        59542728   58.58%
vmdata      zfspool     active       902299648       246187132       656112516   27.28%
vmstore     zfspool     active      1723334656      1003681212       719653444   58.24%
vzhot           dir     active      3844550452      2744304544      1061159352   71.38%
NAME      SIZE  ALLOC   FREE  CKPOINT  EXPANDSZ   FRAG    CAP  DEDUP    HEALTH  ALTROOT
vmdata    888G   235G   653G        -         -    25%    26%  1.00x    ONLINE  -
vmstore  1.66T   957G   739G        -         -     9%    56%  1.00x    ONLINE  -
ARC size=8.0 GiB
```

## Containers (cthost01)
```
```
