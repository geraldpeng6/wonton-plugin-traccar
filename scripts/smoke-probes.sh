# shellcheck shell=bash
# 真实冒烟（e2e/smoke.sh）的探针：变量只有 SMOKE_STATE、SMOKE_JAR、SMOKE_WEB_URL、SMOKE_OWNER、SMOKE_BASE、
# SMOKE_TOKEN、SMOKE_INSTANCE 和 web_get、dweb 两个函数，set -u 下跑；不要用模板套件里多的变量（SMOKE_PLUGIN_ID、
# SMOKE_WEB_ORIGIN 等）和 jq（冒烟机不保证有）。解析响应只用 grep。

web_login() { # 上游 OIDC 入口 /api/session/openid/auth 是 JSON 端点，Accept 不含 */* 会被 JAX-RS 406，
  # 默认登录跳转的 text/html 走不通；带 */* 的浏览器式 Accept 顺着 302 链走完（核心会话已在 $SMOKE_JAR）。
  local url="${1:-$SMOKE_WEB_URL}" out code hops=0
  while :; do
    out="$(curl -sS --noproxy '*' -o /dev/null -b "$SMOKE_JAR" -c "$SMOKE_JAR" \
      -w '%{http_code} %{redirect_url}' --max-time 30 \
      -A 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150 Safari/537.36' \
      -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' \
      "$url" 2>/dev/null)" || { echo "登录跳转请求失败：$url"; return 1; }
    code="${out%% *}"
    case "$code" in
      3*)
        url="${out#* }"
        if [ -z "$url" ] || [ "$url" = "$out" ]; then
          echo "登录跳转 HTTP $code 没有下一跳"
          return 1
        fi
        hops=$((hops + 1))
        [ "$hops" -le 25 ] || { echo "登录跳转超过 25 跳"; return 1; }
        ;;
      2*) return 0 ;;
      *) echo "登录跳转失败：HTTP $code（$url）"; return 1 ;;
    esac
  done
}

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
