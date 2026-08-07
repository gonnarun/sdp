#!/usr/bin/env bash
# sdp-config.sh — minimal, dependency-free YAML reader for SDP config.
# POSIX awk only (NFR-01). Handles scalar keys, arbitrary indentation-based
# nesting, and simple `[a, b]` inline lists. NOT a general YAML parser — only
# the subset SDP config uses. Full 2-layer merge lives in sdp_cfg_merge().
#
# This reader is written to the SAME semantics as review_gate.py's
# _read_gates_yaml (indent-stack nesting, quote-aware comment stripping,
# colonless-line rejection); tests/config_safety.sh asserts they agree
# (REQ-026/027 parity test).

# sdp_cfg_get FILE DOTTED_KEY  -> prints the scalar value (empty if absent)
# Supports: "top" and any depth of "parent.child.grandchild" via an indent
# stack (NOT depth=int(indent/2), which assumed exactly 2-space indents and
# collapsed >=2 levels into a parent0.key collision — REQ-026 / L8).
# Returns exit 2 (prints nothing) if the wanted value has an unterminated quote.
sdp_cfg_get() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  awk -v want="$key" '
    function trim(s){ sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s }
    function strip_q(s){ gsub(/^["\x27]|["\x27]$/,"",s); return s }
    # quote-aware inline-comment strip (REQ-027 / L9): a # inside a quote is a
    # literal char, not a comment; keep the quote chars for strip_q downstream.
    function strip_comment(s,   out,i,ch,q){
      out=""; q=""
      for(i=1;i<=length(s);i++){
        ch=substr(s,i,1)
        if(q!=""){ out=out ch; if(ch==q) q="" }
        else if(ch=="\"" || ch=="\x27"){ q=ch; out=out ch }
        else if(ch=="#"){ break }
        else out=out ch
      }
      return out
    }
    {
      line=strip_comment($0)
      if(trim(line)=="") next
      match(line, /^[ ]*/); indent=RLENGTH
      s=trim(line)
      ci=index(s, ":")
      if(ci<=0) next                               # colonless line -> not a mapping entry (REQ-027)
      k=strip_q(trim(substr(s,1,ci-1)))
      vraw=trim(strip_comment(substr(s,ci+1)))
      while(sp>0 && si[sp]>=indent){ sp-- }        # indent stack: pop shallower/equal frames
      path=(sp==0)?"":sk[1]
      for(i=2;i<=sp;i++){ path=path "." sk[i] }
      path=(path=="")?k:path "." k
      vval=strip_q(vraw)
      if(vval!=""){
        if(path==want){
          f1=substr(vraw,1,1); lc=substr(vraw,length(vraw),1)
          if((f1=="\""   && (length(vraw)<2||lc!="\""))   ||
             (f1=="\x27" && (length(vraw)<2||lc!="\x27"))){ exit 2 }   # unterminated quote (REQ-027)
          print vval; exit
        }
      } else {
        sp++; sk[sp]=k; si[sp]=indent              # empty value -> a nesting parent
      }
    }
  ' "$file"
}

# sdp_cfg_base_dir BASE_FILE   -> base_dir with default. An unterminated quote
# on the base_dir value is FATAL (REQ-027 / L9): the artifact root must never be
# silently mis-parsed into a wrong (possibly committable) directory.
sdp_cfg_base_dir() {
  local file="$1" v rc
  v="$(sdp_cfg_get "$file" base_dir)"; rc=$?
  if [ "$rc" -eq 2 ]; then
    printf 'ERROR: base_dir in %s has an unterminated quote — refused\n' "$file" >&2
    return 2
  fi
  [ -n "$v" ] && printf '%s\n' "$v" || printf '%s\n' ".private/sdp-artifacts"
}

# sdp_cfg_check_no_weakening DEFAULTS_FILE
# Fail (exit 1) if the project's forced_ext turns a base safety key OFF.
# Base safety keys must only strengthen (true) — never be set false. (REQ-U-04)
sdp_cfg_check_no_weakening() {
  local file="$1"
  [ -f "$file" ] || return 0
  # FAIL-CLOSED parse of the forced_ext block (the line-based reader alone was bypassable via multi-line flow
  # maps, next-line/quoted values, and null). Rule: a base safety key, if present under forced_ext, MUST be set
  # to a truthy literal (true/yes/on) ON ITS OWN LINE. Anything else — false/no/off/0/null/~, an empty/next-line
  # value, a quoted key, or ANY non-empty `{...}` inline flow — is treated as a weakening/ambiguity and BLOCKs.
  # shellcheck disable=SC1083  # the { below are awk-program syntax inside the single-quoted awk string, not shell brace groups
  awk '
    function trim(s){ sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s }
    function indw(s){ match(s,/^[ \t]*/); return RLENGTH }   # count leading SPACES AND TABS (tab-indented blocks)
    function unq(s){ gsub(/^["\x27]|["\x27]$/,"",s); return s }
    BEGIN{
      split("hardcoded_secret_block redact_secrets no_auto_push_to_main sandbox_outputs_under_base_dir migration_creation_requires_approval", a, " ");
      for(i in a) base[a[i]]=1; infe=0; feind=-1; bad=0;
    }
    /^[ \t]*#/ { next }
    { raw=$0; sub(/\r$/,"",raw); il=indw(raw); t=trim(raw); if(t=="") next   # strip CR (CRLF configs) before parsing
      if(infe && il<=feind){ infe=0 }            # dedent: leave the block, then RE-EVALUATE this line as a header
      if(!infe){                                 # (so a SECOND `forced_ext:` block cannot slip past — reopens here)
        # match forced_ext whether the key is bare or quoted ("forced_ext": / '"'"'forced_ext'"'"':)
        thead=t; ci0=index(thead,":"); tkey=(ci0>0)?unq(trim(substr(thead,1,ci0-1))):"";
        if(tkey=="forced_ext"){
          rest=trim(substr(thead,ci0+1));
          if(rest ~ /\{[[:space:]]*\}/){ }        # truly empty {} on one line -> harmless
          else if(rest ~ /\{/){ printf "CONFIG ERROR: forced_ext inline/multi-line flow { } not allowed — use a block map (fail-closed)\n" > "/dev/stderr"; bad=1 }  # any other { (content, or a bare '{' opening a multi-line flow) -> fail closed
          else { infe=1; feind=il }               # block map follows
        }
        else if(tkey ~ /^forced_ext\./){          # FLAT dotted key `forced_ext.<subkey>: v` — sdp_cfg_get resolves it
          subk=tkey; sub(/^forced_ext\./,"",subk) # by literal name, so it can weaken a base key without a block header
          if(subk in base){
            dv=substr(thead,ci0+1); sub(/[ \t]+#.*$/,"",dv); dv=trim(dv); gsub(/^["\x27]|["\x27]$/,"",dv); dvl=tolower(dv)
            if(dvl!="true" && dvl!="yes" && dvl!="on"){ printf "CONFIG ERROR: forced_ext.%s (dotted key) must be a truthy literal; got \"%s\" (fail-closed)\n", subk, dv > "/dev/stderr"; bad=1 }
          }
        }
        next
      }
      # inside forced_ext block
      if(t ~ /\{/){ printf "CONFIG ERROR: forced_ext inline flow { } not allowed (fail-closed)\n" > "/dev/stderr"; bad=1; next }
      ci=index(t,":")
      if(ci<=0){ if(unq(t) in base){ printf "CONFIG ERROR: forced_ext.%s has no value (colonless) — ambiguous, only `%s: true` strengthens (fail-closed)\n", unq(t), unq(t) > "/dev/stderr"; bad=1 } next }  # colonless base key -> weakening
      k=trim(substr(t,1,ci-1)); v=trim(substr(t,ci+1));
      gsub(/^["\x27]|["\x27]$/,"",k)               # strip key quotes
      sub(/[ \t]+#.*$/,"",v); v=trim(v); gsub(/^["\x27]|["\x27]$/,"",v); vl=tolower(v)
      if(k in base){
        if(vl!="true" && vl!="yes" && vl!="on"){
          printf "CONFIG ERROR: forced_ext.%s must be a truthy literal on its line (only strengthening allowed); got \"%s\"\n", k, v > "/dev/stderr";
          bad=1
        }
      }
    }
    END{ exit bad }
  ' "$file"
}
