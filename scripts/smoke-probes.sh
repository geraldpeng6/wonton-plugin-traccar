# shellcheck shell=bash
# 真实冒烟（e2e/smoke.sh）的探针：变量只有 SMOKE_STATE、SMOKE_JAR、SMOKE_WEB_URL、SMOKE_OWNER、SMOKE_BASE、
# SMOKE_TOKEN、SMOKE_INSTANCE 和 web_get、dweb 两个函数，set -u 下跑；不要用模板套件里多的变量（SMOKE_PLUGIN_ID、
# SMOKE_WEB_ORIGIN 等）和 jq（冒烟机不保证有）。解析响应只用 grep。

web_assert() { grep -q '<title>Traccar</title>'; }

identity_check() { # /api/session 回当前用户：管理员 + 核心给的 email（<用户名>@…），证明 OIDC 组映射生效
  local out
  out="$(dweb /api/session 2>/dev/null)" || out=""
  if ! grep -q '"administrator":true' <<<"$out"; then
    dweb / >/dev/null 2>&1 || true # 走一遍网页入口，建立应用自己的会话再试
    out="$(dweb /api/session 2>/dev/null)" || out=""
  fi
  if grep -q '"administrator":true' <<<"$out" \
    && grep -qi "\"email\":\"$SMOKE_OWNER@" <<<"$out"; then
    return 0
  fi
  echo "当前用户不是管理员或邮箱对不上：$(head -c 200 <<<"$out")"
  return 1
}

data_write() { # 建一台名字带随机标记的设备，标记存进 $SMOKE_STATE
  local marker out
  marker="smoke-$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')"
  if ! out="$(dweb /api/devices -X POST -H 'Content-Type: application/json' \
    -d "{\"name\":\"$marker\",\"uniqueId\":\"$marker\"}" 2>/dev/null)"; then
    echo "建设备失败：$(head -c 200 <<<"${out:-空响应}")"
    return 1
  fi
  if ! grep -q "\"name\":\"$marker\"" <<<"$out"; then
    echo "建设备失败：$(head -c 200 <<<"$out")"
    return 1
  fi
  printf '%s' "$marker" >"$SMOKE_STATE"
}

data_check() { # 重装（保数据）后设备还在
  local marker out
  marker="$(cat "$SMOKE_STATE")"
  out="$(dweb /api/devices 2>/dev/null)" || { echo "列设备失败：$out"; return 1; }
  grep -q "\"name\":\"$marker\"" <<<"$out" \
    || { echo "找不到设备 $marker：$(head -c 200 <<<"$out")"; return 1; }
}
