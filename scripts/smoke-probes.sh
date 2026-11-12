# shellcheck shell=bash
# 真实冒烟（e2e/smoke.sh）的探针：变量只有 SMOKE_STATE、SMOKE_JAR、SMOKE_WEB_URL、SMOKE_OWNER、SMOKE_BASE、
# SMOKE_TOKEN、SMOKE_INSTANCE 和 web_get、dweb 两个函数，set -u 下跑；不要用模板套件里多的变量（SMOKE_PLUGIN_ID、
# SMOKE_WEB_ORIGIN 等）和 jq（冒烟机不保证有）。解析响应只用 grep。
#
# 不用 dweb / web_get：dweb 调 scripts/dev.sh web，登录跳转发 Accept: text/html（无通配符），上游 OIDC 的
# JSON 端点按内容协商 406（模板开发套件问题，见 PR 底座的问题）；web_get 把路径拼在入口后面，本插件入口
# 自带路径（OIDC 端点），拼出来不是接口地址。这里直接带会话 jar 请求入口源上的 API 路径。
# 重装保数据后上游的内存会话会丢：探针遇失败就用契约变量重走一次登录（核心令牌登录，再以浏览器式
# Accept 跟完入口的 SSO 链），然后重试。

sso_origin() { # SMOKE_WEB_URL 的 scheme://host:port
  printf '%s' "$SMOKE_WEB_URL" | sed -E 's#^(https?://[^/]+).*$#\1#'
}

sso_relogin() { # 会话失效时重走登录
  curl -sS --noproxy '*' --max-time 120 -o /dev/null -c "$SMOKE_JAR" \
    --data-urlencode "token=$SMOKE_TOKEN" "$SMOKE_BASE/_wonton/login" || return 1
  curl -sS --noproxy '*' --max-time 120 -o /dev/null -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" \
    -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' \
    "$SMOKE_WEB_URL"
}

api() { local path="$1"; shift; curl -sS --noproxy '*' -f --max-time 60 -b "$SMOKE_JAR" -c "$SMOKE_JAR" "$(sso_origin)$path" "$@"; }

api_retry() { # api 一把，失败就重走登录再试一次；输出成功那次的响应
  local out
  out="$(api "$@" 2>/dev/null)" && { printf '%s' "$out"; return 0; }
  sso_relogin >/dev/null 2>&1 || { echo "重走登录失败"; return 1; }
  api "$@" 2>/dev/null
}

web_assert() { grep -q '<title>Traccar</title>'; }

identity_check() { # /api/session 回当前用户：管理员 + 核心给的 email（<用户名>@…），证明 OIDC 组映射生效
  local out
  out="$(api_retry /api/session)" || out=""
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
  if ! out="$(api_retry /api/devices -X POST -H 'Content-Type: application/json' \
    -d "{\"name\":\"$marker\",\"uniqueId\":\"$marker\"}")"; then
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
  out="$(api_retry /api/devices)" || { echo "列设备失败：$out"; return 1; }
  grep -q "\"name\":\"$marker\"" <<<"$out" \
    || { echo "找不到设备 $marker：$(head -c 200 <<<"$out")"; return 1; }
}
