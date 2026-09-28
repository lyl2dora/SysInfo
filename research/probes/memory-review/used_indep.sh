#!/bin/zsh
# used_indep.sh - independent "Memory Used" (Activity-Monitor-style) from non-rate-limited sysctls + vm_stat (platform binary),
# next to the other agent's Stats replica (host_statistics64) and top's PhysMem line, taken back-to-back.
R=${PROBE_OUT:-${TMPDIR:-/tmp}/sysinfo-probes}/memory
PS=$(sysctl -n vm.pagesize)
INT=$(sysctl -n vm.page_pageable_internal_count); PURG=$(sysctl -n vm.page_purgeable_count); WIRE=$(sysctl -n vm.page_wired_count)
THR=$(sysctl -n vm.page_throttled_count); EXT=$(sysctl -n vm.page_pageable_external_count); FREE=$(sysctl -n vm.page_free_count); SPEC=$(sysctl -n vm.page_speculative_count)
OCC=$(vm_stat | awk -F: '/occupied by compressor/{gsub(/[ .]/,"",$2);print $2}')
BOOT=$(sysctl -n vm.page_booter_count); USABLE=$(sysctl -n hw.memsize_usable)
echo "sysctl: internal=$INT purgeable=$PURG wired=$WIRE throttled=$THR external=$EXT free=$FREE spec=$SPEC booter=$BOOT | vm_stat compressor-occupied=$OCC"
awk -v i=$INT -v p=$PURG -v w=$WIRE -v t=$THR -v c=$OCC -v e=$EXT -v f=$FREE -v s=$SPEC -v ps=$PS -v u=$USABLE 'BEGIN{G=1073741824; app=(i-p)*ps; wired=(w+t)*ps; comp=c*ps; used=app+wired+comp;
  printf "independent: app=%.3f GiB wired=%.3f compressed=%.3f used=%.3f cached(ext+purg)=%.3f free(free+spec)=%.3f  queue-sum(free+spec+int+ext+wired+comp)=%.3f vs memsize_usable %.3f\n",app/G,wired/G,comp/G,used/G,(e+p)*ps/G,(f+s)*ps/G,(f+s+i+e+w+t+c)*ps/G,u/G}'
$R/stats_usage_replica | head -1
top -l 1 -n 0 | grep PhysMem
