#!/usr/bin/env bash
# Claude Code statusline — bash port of statusline.ps1
# Reads JSON from stdin, prints a single ANSI-colored status line.
#
# Layout: <ctx used/max> | <model> | <⎇ branch> | <cwd> | <turns (steps)> | <⚡ tok/s> | <5h quota> | <week quota> | <cpu %>
#
# 上下文用量按使用率分档(绿→青→黄→红);tok/s 是上一次响应的瞬时速度,
# 通过 ~/.claude/.statusline-speed-<session_id>.json 缓存累计值做差分,
# 避免多窗口/多 session 互串。首次调用无缓存时退化为"全会话平均"并标 avg。

# ---- ANSI 颜色 ----
ESC=$'\033'
RESET="${ESC}[0m"
DIM="${ESC}[2m"          # 暗色:辅助信息、分隔符
BOLD="${ESC}[1m"         # 加粗:主数字
YELLOW="${ESC}[33m"
CYAN="${ESC}[36m"
GREEN="${ESC}[32m"
MAGENTA="${ESC}[35m"     # 模型品牌色
RED="${ESC}[31m"         # 危险:上下文将满
BRIGHTBLACK="${ESC}[90m" # 工作目录:存在感最弱

# ---- Helpers ----
format_tokens() {
    # 1234 -> "1k", 1500000 -> "1.5m"
    awk -v n="$1" 'BEGIN {
        if (n >= 1000000) printf "%.1fm", n / 1000000
        else if (n >= 1000) printf "%.0fk", n / 1000
        else printf "%d", n
    }'
}

context_color() {
    # ratio in [0,1] -> ANSI
    awk -v r="$1" -v red="$RED" -v yel="$YELLOW" -v cy="$CYAN" -v gr="$GREEN" 'BEGIN {
        if (r >= 0.9) print red; else if (r >= 0.7) print yel
        else if (r >= 0.4) print cy; else print gr
    }'
}

speed_color() {
    # tps in tok/s -> ANSI(慢黄 / 中青 / 快绿)
    awk -v t="$1" -v yel="$YELLOW" -v cy="$CYAN" -v gr="$GREEN" 'BEGIN {
        if (t < 50) print yel; else if (t < 150) print cy; else print gr
    }'
}

# ---- 读 stdin (带超时,避免 Claude Code 卡住) ----
json=$(timeout 3 cat 2>/dev/null)
if [[ -z "${json//[[:space:]]/}" ]]; then
    echo 'Claude Code'
    exit 0
fi

# ---- 解析 JSON ----
# 兼容:Claude Code 偶尔传 array,取首元素
data=$(jq -c 'if type == "array" then .[0] else . end' <<<"$json" 2>/dev/null)
if [[ -z "$data" || "$data" == "null" ]]; then
    echo 'Claude Code'
    exit 0
fi

# 一次性提取所需字段(tab 分隔)
IFS=$'\t' read -r max used_pct model dir session_id cur_output cur_api_ms last_usage in_new transcript < <(
    jq -r '[
        (.context_window.context_window_size // 0),
        (.context_window.used_percentage // ""),
        (.model.display_name // ""),
        (.workspace.current_dir // ""),
        (.session_id // ""),
        (.context_window.total_output_tokens // 0),
        (.cost.total_api_duration_ms // 0),
        (.context_window.current_usage.output_tokens // ""),
        (.context_window.current_usage.input_tokens // 0),
        (.transcript_path // "")
    ] | map(tostring | if . == "" then "-" else . end) | @tsv' <<<"$data"
)
for v in used_pct model dir session_id last_usage transcript; do
    [[ "${!v}" == "-" ]] && printf -v "$v" ''
done
max=${max%.*}; cur_output=${cur_output%.*}; cur_api_ms=${cur_api_ms%.*}; in_new=${in_new%.*}

# 记录当前会话 session_id 供退出后注入 bash 历史恢复
if [[ -n "$session_id" ]]; then
    mkdir -p "$HOME/.claude/sessions" 2>/dev/null
    # clauded 通过环境变量指定本次启动的邮箱（第 1 行 session_id，第 2 行 transcript 路径）
    [[ -n "$CLAUDE_SESSION_MAILBOX" ]] && printf '%s\n%s\n' "$session_id" "$transcript" > "$CLAUDE_SESSION_MAILBOX" 2>/dev/null
    printf '%s\n' "$session_id" > "$HOME/.claude/sessions/last_session" 2>/dev/null
fi

parts=()

# ---- 上下文用量:数字加粗 + 按使用率分档变色,分母用暗色 ----
# ⚠️ 别用 current_usage.input_tokens — prompt caching 开启时它只算
# 本次请求的"新 input",不含 cache_read 部分,长 session 渲染成 0-3 位。
# 同样别用 total_input_tokens — 那是 session 累计,越加越大。
# 唯一稳的来源:used_percentage(Claude Code 按真实上下文预计算)。
# 注意:不同版本下 used_percentage 可能是 0-100 百分数,也可能是 0-1 小数。
# 自动检测:>1 当百分数,≤1 当小数。
if (( max > 0 )) && [[ -n "$used_pct" ]]; then
    read -r used ratio < <(awk -v p="$used_pct" -v m="$max" 'BEGIN {
        r = (p > 1) ? p / 100 : p
        printf "%d %f\n", r * m, r
    }')
    u=$(format_tokens "$used")
    m=$(format_tokens "$max")
    c=$(context_color "$ratio")
    parts+=("${c}${BOLD}${u}${RESET}${DIM}/${m}${RESET}")
fi

# ---- 模型名:紫色品牌色 ----
if [[ -n "$model" ]]; then
    parts+=("${MAGENTA}${model}${RESET}")
fi

# ---- Git 分支:青色,带分支符号 ----
branch=$(git -C "${dir:-.}" rev-parse --abbrev-ref HEAD 2>/dev/null)
if [[ -n "$branch" && "$branch" != "HEAD" ]]; then
    parts+=("${CYAN}⎇ ${branch}${RESET}")
fi

# ---- 工作目录:亮黑色(暗),$HOME 替换为 ~ ----
if [[ -n "$dir" ]]; then
    if [[ -n "$HOME" && "$dir" == "$HOME"* ]]; then
        dir="~${dir#"$HOME"}"
    fi
    parts+=("${BRIGHTBLACK}${dir}${RESET}")
fi

# ---- 轮次 / 步数:N turns (M steps) ----
# 参考 pi-extensions/status-footer:turn = 用户真实输入,step = assistant 消息(一次 API 调用)。
# 从 transcript jsonl 统计:
#   turn  排除 tool_result、isMeta、/命令、!bash、中断标记、compact 摘要、sidechain
#   step  按 message.id 去重(一次响应的 thinking/text/tool_use 各占一行,id 相同)
# 增量解析:缓存已读字节偏移 + 计数 + 最后 msg id,只读新增的完整行。
if [[ -n "$session_id" && -f "$transcript" ]]; then
    ts_state="$HOME/.claude/.statusline-turns-${session_id}"
    ts_off=0 turns=0 steps=0 ts_last=''
    [[ -f "$ts_state" ]] && read -r ts_off turns steps ts_last <"$ts_state"
    ts_size=$(stat -c %s "$transcript" 2>/dev/null || echo 0)
    (( ts_size < ts_off )) && ts_off=0 turns=0 steps=0 ts_last=''   # 文件被重写
    if (( ts_size > ts_off )); then
        ts_tmp="$ts_state.chunk.$$"
        tail -c +$(( ts_off + 1 )) "$transcript" | head -c $(( ts_size - ts_off )) >"$ts_tmp"
        # 末行可能写了一半:不计入,下次再读
        ts_len=$(( ts_size - ts_off ))
        if [[ -n "$(tail -c 1 "$ts_tmp")" ]]; then
            ts_len=$(( ts_len - $(tail -n 1 "$ts_tmp" | wc -c) ))
        fi
        if (( ts_len > 0 )); then
            read -r turns steps ts_last < <(
                head -c "$ts_len" "$ts_tmp" | jq -rR '
                    fromjson? | select(.isSidechain != true) |
                    if .type == "user" and (.isMeta | not) and (.isCompactSummary | not) then
                        (.message.content
                         | if type == "string" then .
                           elif type == "array" then ([.[] | select(.type == "text") | .text] | first // "")
                           else "" end) as $t
                        | select($t != ""
                                 and ($t | test("^\\s*<(command-|local-command|bash-|task-notification|system-reminder)") | not)
                                 and ($t | startswith("[Request interrupted") | not))
                        | "T"
                    elif .type == "assistant" and .message.model != "<synthetic>" and .message.id != null then
                        "S \(.message.id)"
                    else empty end' 2>/dev/null |
                awk -v t="$turns" -v s="$steps" -v last="${ts_last:--}" '
                    $1 == "T" { t++ }
                    $1 == "S" && $2 != last { s++; last = $2 }
                    END { print t, s, last }'
            )
            ts_off=$(( ts_off + ts_len ))
            printf '%s %s %s %s\n' "$ts_off" "$turns" "$steps" "${ts_last:--}" >"$ts_state.$$" 2>/dev/null \
                && mv -f "$ts_state.$$" "$ts_state" 2>/dev/null
        fi
        rm -f "$ts_tmp"
    fi
    if (( turns > 0 )); then
        tw=turns; (( turns == 1 )) && tw=turn
        sw=steps; (( steps == 1 )) && sw=step
        seg="${CYAN}${turns} ${tw}${RESET}"
        (( steps > 0 )) && seg+="${DIM} (${steps} ${sw})${RESET}"
        parts+=("$seg")
    fi
fi

# ---- Token output speed (上次响应 tok/s) + 本轮输入 ----
# 这是 Claude Code 内置接口能拿到的最详细数据 — hook/plugin 都拿不到 token。
# 缺点:没有 TTFT,只能算 output token 的平均吞吐。
# 本轮输入 = 当前请求的"新 input"部分(不含 cache hit)
in_fmt=$(format_tokens "${in_new:-0}")

if [[ -n "$session_id" ]] && (( cur_api_ms > 0 )); then
    state_file="$HOME/.claude/.statusline-speed-${session_id}.json"

    # 读上次快照:累计值(做差分)+ 上次展示的速度(无新数据时复用)
    delta_output=0
    delta_api_ms=0
    last_tps='' last_sec='' last_out='' last_avg=''
    if [[ -f "$state_file" ]]; then
        IFS=$'\t' read -r prev_out prev_ms last_tps last_sec last_out last_avg < <(
            jq -r '[(.output // 0), (.api_ms // 0), (.tps // "-"), (.sec // "-"), (.out // "-"), (.avg // "-")]
                   | map(tostring) | @tsv' "$state_file" 2>/dev/null
        )
        if [[ -n "$prev_out" ]]; then
            delta_output=$(( cur_output - ${prev_out%.*} ))
            delta_api_ms=$(( cur_api_ms - ${prev_ms%.*} ))
        fi
        [[ "$last_tps" == "-" ]] && last_tps=''
    fi

    tps='' sec='' out_fmt='' avg=''
    if (( delta_output > 0 && delta_api_ms > 0 )); then
        # 上次响应的瞬时速度
        tps=$(awk -v o="$delta_output" -v ms="$delta_api_ms" 'BEGIN { printf "%.1f", o * 1000 / ms }')
        sec=$(awk -v ms="$delta_api_ms" 'BEGIN { printf "%.1f", ms / 1000 }')
        out_fmt=$(format_tokens "$delta_output")
        avg=0
    elif [[ -n "$last_tps" ]]; then
        # 累计值没变(refreshInterval 定时重跑 / 非响应类触发)→ 复用上次结果,
        # 否则差分为 0 会误退化成 avg
        tps=$last_tps sec=$last_sec out_fmt=$last_out avg=$last_avg
    elif [[ -n "$last_usage" && "$last_usage" != "0" ]]; then
        # 无缓存 → 退化为"全会话平均速度",标 avg 区分
        tps=$(awk -v o="$cur_output" -v ms="$cur_api_ms" 'BEGIN { printf "%.1f", o * 1000 / ms }')
        sec=$(awk -v ms="$cur_api_ms" 'BEGIN { printf "%.1f", ms / 1000 }')
        out_fmt=$(format_tokens "$last_usage")
        avg=1
    fi

    # 落盘当前快照供下次差分(先写临时文件再 mv,避免并发渲染读到半截)
    mkdir -p "$HOME/.claude" 2>/dev/null
    jq -nc --argjson o "$cur_output" --argjson ms "$cur_api_ms" \
        --arg tps "$tps" --arg sec "$sec" --arg out "$out_fmt" --arg avg "$avg" \
        '{output: $o, api_ms: $ms} + (if $tps == "" then {} else {tps: $tps, sec: $sec, out: $out, avg: $avg} end)' \
        >"$state_file.$$" 2>/dev/null && mv -f "$state_file.$$" "$state_file" 2>/dev/null

    if [[ -n "$tps" ]]; then
        c=$(speed_color "$tps")
        tag=''
        [[ "$avg" == "1" ]] && tag=' avg'
        parts+=("${c}${BOLD}⚡ ${tps}t/s${RESET}${DIM}${tag} ${sec}s ↑${in_fmt} ↓${out_fmt}${RESET}")
    fi
fi

# ---- 会话花费(照抄 pi status-footer):$总 ($缓存读 + $缓存写 + $输入 + $输出) [M:$主 | S:$子代理] ----
# 价格表 ~/.claude/pricing.json(USD/百万token,按模型前缀最长匹配)。
# 从 transcript 的 message.usage 计算,按 message.id 去重;主 transcript 与
# <session_id>/subagents/agent-*.jsonl 各自增量解析(缓存字节偏移+累计值)。
# 括号内三项只含主会话(同 pi 的 parentTotals),总额含子代理。
cost_pricing="$HOME/.claude/pricing.json"
if [[ -n "$session_id" && -f "$transcript" && -f "$cost_pricing" ]]; then
    cs_state="$HOME/.claude/.statusline-cost2-${session_id}"
    declare -A cs_off cs_cc cs_cw cs_ci cs_co cs_id
    if [[ -f "$cs_state" ]]; then
        while IFS=$'\t' read -r f o cc cw ci co lid; do
            [[ -z "$f" ]] && continue
            cs_off[$f]=$o cs_cc[$f]=$cc cs_cw[$f]=$cw cs_ci[$f]=$ci cs_co[$f]=$co cs_id[$f]=$lid
        done <"$cs_state"
    fi
    cs_files=("$transcript")
    cs_subdir="${transcript%.jsonl}/subagents"
    [[ -d "$cs_subdir" ]] && cs_files+=("$cs_subdir"/agent-*.jsonl)
    cs_dirty=0
    for f in "${cs_files[@]}"; do
        [[ -f "$f" ]] || continue
        o=${cs_off[$f]:-0}; cc=${cs_cc[$f]:-0}; cw=${cs_cw[$f]:-0}; ci=${cs_ci[$f]:-0}; co=${cs_co[$f]:-0}; lid=${cs_id[$f]:--}
        sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
        (( sz < o )) && o=0 cc=0 cw=0 ci=0 co=0 lid=-
        (( sz > o )) || { cs_off[$f]=$o cs_cc[$f]=$cc cs_cw[$f]=$cw cs_ci[$f]=$ci cs_co[$f]=$co cs_id[$f]=$lid; continue; }
        tmp="$cs_state.chunk.$$"
        tail -c +$(( o + 1 )) "$f" | head -c $(( sz - o )) >"$tmp"
        len=$(( sz - o ))
        [[ -n "$(tail -c 1 "$tmp")" ]] && len=$(( len - $(tail -n 1 "$tmp" | wc -c) ))
        if (( len > 0 )); then
            read -r cc cw ci co lid < <(
                head -c "$len" "$tmp" | jq -rR --slurpfile P "$cost_pricing" '
                    fromjson? | select(.type == "assistant" and .message.usage != null and .message.id != null) |
                    .message as $m | $m.usage as $u |
                    ([$P[0] | to_entries[] | select(.key | startswith("_") | not) | select(.key as $k | ($m.model // "") | startswith($k))]
                      | sort_by(.key | length) | last | .value) as $p |
                    select($p != null) |
                    (($u.input_tokens // 0) + ($u.cache_read_input_tokens // 0) + ($u.cache_creation_input_tokens // 0)) as $plen |
                    (if ($p.long_threshold != null and $plen > $p.long_threshold) then $p.long else $p end) as $p |
                    (($u.cache_creation.ephemeral_5m_input_tokens // $u.cache_creation_input_tokens // 0) as $w5 |
                     ($u.cache_creation.ephemeral_1h_input_tokens // 0) as $w1 |
                     "\($m.id) \((($u.cache_read_input_tokens // 0) * $p.cache_read) / 1e6) \(($w5 * $p.w5m + $w1 * $p.w1h) / 1e6) \((($u.input_tokens // 0) * $p["in"]) / 1e6) \((($u.output_tokens // 0) * $p.out) / 1e6)")' 2>/dev/null |
                awk -v cc="$cc" -v cw="$cw" -v ci="$ci" -v co="$co" -v last="$lid" '
                    $1 != last { cc += $2; cw += $3; ci += $4; co += $5; last = $1 }
                    END { printf "%.8f %.8f %.8f %.8f %s\n", cc, cw, ci, co, last }'
            )
            o=$(( o + len )); cs_dirty=1
        fi
        rm -f "$tmp"
        cs_off[$f]=$o cs_cc[$f]=$cc cs_cw[$f]=$cw cs_ci[$f]=$ci cs_co[$f]=$co cs_id[$f]=$lid
    done
    if (( cs_dirty )); then
        for f in "${!cs_off[@]}"; do
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$f" "${cs_off[$f]}" "${cs_cc[$f]}" "${cs_cw[$f]}" "${cs_ci[$f]}" "${cs_co[$f]}" "${cs_id[$f]}"
        done >"$cs_state.$$" 2>/dev/null && mv -f "$cs_state.$$" "$cs_state" 2>/dev/null
    fi
    read -r m_cc m_cw m_ci m_co s_tot < <(
        for f in "${!cs_off[@]}"; do
            [[ "$f" == "$transcript" ]] && k=M || k=S
            echo "$k ${cs_cc[$f]} ${cs_cw[$f]} ${cs_ci[$f]} ${cs_co[$f]}"
        done | awk '$1=="M"{mc+=$2;mw+=$3;mi+=$4;mo+=$5} $1=="S"{s+=$2+$3+$4+$5} END{printf "%f %f %f %f %f\n", mc, mw, mi, mo, s}')
    cost_seg=$(awk -v mc="${m_cc:-0}" -v mw="${m_cw:-0}" -v mi="${m_ci:-0}" -v mo="${m_co:-0}" -v s="${s_tot:-0}" \
        -v Y="$YELLOW" -v C="$CYAN" -v B="${ESC}[97m" -v M="$MAGENTA" -v G="$GREEN" -v D="$DIM" -v R="$RESET" '
        function usd(v) { if (v <= 0) return "0"; if (v < 0.01) return sprintf("%.4f", v); if (v < 1) return sprintf("%.3f", v); return sprintf("%.2f", v) }
        BEGIN {
            m = mc + mw + mi + mo; t = m + s
            if (t <= 0) exit
            out = Y "$" usd(t) R
            if (m > 0) out = out D " (" R C "r$" usd(mc) R D " + " R M "w$" usd(mw) R D " + " R B "i$" usd(mi) R D " + " R G "o$" usd(mo) R D ")" R
            if (s > 0) out = out D " [M:" R Y "$" usd(m) R D " | S:" R Y "$" usd(s) R D "]" R
            print out
        }')
    [[ -n "$cost_seg" ]] && parts+=("$cost_seg")
    unset cs_off cs_cc cs_cw cs_ci cs_co cs_id
fi

# ---- 订阅用量 (/usage):5h / 7d 剩余 bar + 节奏偏差 + 距重置时间 ----
# rate_limits.{five_hour,seven_day}.{used_percentage, resets_at(epoch 秒)}
# 仅订阅用户、且本 session 收到过一次 API 响应后才有。
# 渲染参考 pi-extensions/quota-footer (codex provider):
#   5h ███████░░░ 76% -1h38m 0.7x 2h13m
#   bar/百分比 = 剩余额度(<30 红 / <60 黄 / 否则绿)
#   delta = 已用比例折算的时间 - 窗口已过时间:+ 超前烧(黄/红),- 省着用(绿)
#   Nx    = 消耗速率相对匀速的倍数(窗口初期 delta 很小时也能看出烧得快)
#   末尾暗色 = 距重置
rl_now=$(date +%s)
while IFS=$'\t' read -r label cycle rl_used rl_reset; do
    [[ -z "$label" ]] && continue
    parts+=("$(awk -v label="$label" -v cycle="$cycle" -v used="$rl_used" -v reset="$rl_reset" -v now="$rl_now" \
        -v red="$RED" -v yel="$YELLOW" -v gr="$GREEN" -v dim="$DIM" -v rs="$RESET" '
    function fmt_reset(s,   m, d, h) {
        if (s <= 0) return ""
        m = int((s + 59) / 60)
        if (m >= 1440) { d = int(m / 1440); h = int((m % 1440) / 60); return d "d" h "h" }
        if (m >= 60) return sprintf("%dh%02dm", int(m / 60), m % 60)
        return m "m"
    }
    function fmt_delta(ds,   sign, a, hrs, m) {
        sign = ds >= 0 ? "+" : "-"; a = ds < 0 ? -ds : ds; hrs = a / 3600
        if (hrs >= 24) return sprintf("%s%.1fd", sign, hrs / 24)
        if (cycle <= 18000) {   # 5h 窗口:精确到分钟
            m = int(a / 60 + 0.5)
            if (m == 0) return "±0m"
            if (m >= 60) return sprintf("%s%dh%02dm", sign, int(m / 60), m % 60)
            return sign m "m"
        }
        if (int(hrs + 0.5) == 0) return "±0h"
        return sign int(hrs + 0.5) "h"
    }
    BEGIN {
        u = int(used + 0.5); if (u < 0) u = 0; if (u > 100) u = 100
        left = 100 - u
        c = left < 30 ? red : (left < 60 ? yel : gr)
        f = int(left / 10 + 0.5); b = ""
        for (i = 0; i < 10; i++) b = b (i < f ? "█" : "░")
        out = c label " " b " " left "%" rs
        if (reset ~ /^[0-9]+$/) {
            remain = reset - now; elapsed = cycle - remain
            if (elapsed > 0 && elapsed < cycle) {
                delta = u / 100 * cycle - elapsed
                dc = gr
                if (delta > 0) dc = (delta > remain * 0.5 || delta > cycle * 0.2) ? red : yel
                # 速率 = 已用比例 / 已过时间比例:1.0x 刚好匀速,2.0x 按此速度一半时间就烧完
                rate = (u / 100 * cycle) / elapsed
                rt = rate >= 10 ? sprintf("%dx", rate) : sprintf("%.1fx", rate)
                out = out " " dc fmt_delta(delta) " " rt rs
            }
            r = fmt_reset(remain)
            if (r != "") out = out " " dim r rs
        }
        print out
    }')")
done < <(jq -r '
    [["5h", 18000, .rate_limits.five_hour], ["week", 604800, .rate_limits.seven_day]][]
    | select(.[2].used_percentage != null)
    | [.[0], (.[1] | tostring), (.[2].used_percentage | tostring), ((.[2].resets_at // "") | tostring | split(".")[0])]
    | @tsv' <<<"$data" 2>/dev/null)

# ---- CPU 使用率:距上次渲染的区间均值 ----
# /proc/stat 累计 jiffies 做差分,不 sleep 采样;所有 session 共用一个快照文件,
# 区间 = 距任一窗口上次渲染(配合 refreshInterval 即最近 N 秒)。首次无快照不显示。
if [[ -r /proc/stat ]]; then
    read -r _ user nice system idle iowait irq softirq steal _ </proc/stat
    cpu_total=$(( user + nice + system + idle + iowait + irq + softirq + steal ))
    cpu_idle=$(( idle + iowait ))
    cpu_state="$HOME/.claude/.statusline-cpu"
    cpu_pct=''
    if [[ -f "$cpu_state" ]]; then
        read -r prev_total prev_idle prev_pct <"$cpu_state"
        # 同 htop (ProcessorList/LinuxMachine):对累计值做饱和减法——iowait 等计数器
        # 在 NOHZ 下可能倒退,直接相减会得到负数 → 百分比 >100;最后再 clamp 到 [0,100]。
        # user/nice 已含 guest/guest_nice,不重复计入。
        d_total=$(( cpu_total - ${prev_total:-0} )); (( d_total < 0 )) && d_total=0
        d_idle=$(( cpu_idle - ${prev_idle:-0} ));    (( d_idle < 0 )) && d_idle=0
        if (( d_total > 0 )); then
            (( d_idle > d_total )) && d_idle=$d_total
            cpu_pct=$(( (d_total - d_idle) * 100 / d_total ))
            (( cpu_pct > 100 )) && cpu_pct=100
        else
            # 两次渲染间隔太短(同一 jiffy 内)→ 复用上次
            cpu_pct=$prev_pct
        fi
    fi
    printf '%s %s %s\n' "$cpu_total" "$cpu_idle" "$cpu_pct" >"$cpu_state.$$" 2>/dev/null \
        && mv -f "$cpu_state.$$" "$cpu_state" 2>/dev/null
    if [[ -n "$cpu_pct" ]]; then
        if (( cpu_pct >= 80 )); then c=$RED
        elif (( cpu_pct >= 50 )); then c=$YELLOW
        else c=$DIM
        fi
        parts+=("${c}cpu ${cpu_pct}%${RESET}")
    fi
fi

# ---- Output ----
if (( ${#parts[@]} == 0 )); then
    echo 'Claude Code'
    exit 0
fi

sep="${DIM} | ${RESET}"
out="${parts[0]}"
for p in "${parts[@]:1}"; do
    out+="${sep}${p}"
done
printf '%s\n' "$out"
