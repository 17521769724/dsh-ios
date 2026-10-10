import Foundation

// MARK: - 云端推理配置

/// 云端推理配置：Agent 部署在用户自己的 SSH 服务器上，
/// iOS 客户端只保存访问地址与令牌（令牌进钥匙串），不保存任何模型 Key。
struct CloudConfiguration: Codable, Equatable {
    /// Agent 服务端口（部署时可改，需在云服务器安全组放行）
    var port: Int = 8931
    /// 默认使用的沙盒 id；首次发送会话时若不存在会自动创建
    var sandboxID: String = "main"
    /// 云端推理选用的 SSH 服务器（多台时可选；为空用列表第一台）
    var sshServerID: UUID?

    static let `default` = CloudConfiguration()

    /// 宽容解码：新增字段在旧数据中缺失时取默认值
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = CloudConfiguration.default
        self.port = try container.decodeIfPresent(Int.self, forKey: .port) ?? fallback.port
        self.sandboxID = try container.decodeIfPresent(String.self, forKey: .sandboxID) ?? fallback.sandboxID
        self.sshServerID = try container.decodeIfPresent(UUID.self, forKey: .sshServerID)
    }

    init(port: Int = 8931, sandboxID: String = "main", sshServerID: UUID? = nil) {
        self.port = port
        self.sandboxID = sandboxID
        self.sshServerID = sshServerID
    }
}

/// 云端推理存储：非敏感项存 UserDefaults，Agent 访问令牌存钥匙串。
/// 令牌只在部署时下发给服务器，之后每次请求用它鉴权（个人自用，不需要注册登录）。
final class CloudStore: ObservableObject {

    @Published var configuration: CloudConfiguration {
        didSet { persist() }
    }

    /// Agent 访问令牌（随机生成，保存在本机钥匙串）
    @Published var token: String {
        didSet { Keychain.set(token, for: Self.tokenAccount) }
    }

    /// 是否正在部署
    @Published var deploying = false
    /// 最近一次连接检测结果：nil 表示未检测
    @Published var healthText: String?
    @Published var lastError: String?

    private static let configKey = "dsh.cloud.config.v1"
    private static let tokenAccount = "cloud.agent.token"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.configKey),
           let decoded = try? JSONDecoder().decode(CloudConfiguration.self, from: data) {
            configuration = decoded
        } else {
            configuration = .default
        }
        let stored = Keychain.get(Self.tokenAccount)
        token = stored.isEmpty ? Self.randomToken() : stored
        // init 里赋值不会触发 didSet，首次生成的令牌要手动落钥匙串
        if stored.isEmpty {
            Keychain.set(token, for: Self.tokenAccount)
        }
    }

    /// 32 位十六进制随机令牌
    static func randomToken() -> String {
        (0..<32).map { _ in String("0123456789abcdef".randomElement() ?? "0") }.joined()
    }

    /// 当前选中的云服务器（未选或已删除时回退第一台）
    func selectedServer(in servers: [SSHServer]) -> SSHServer? {
        if let id = configuration.sshServerID, let match = servers.first(where: { $0.id == id }) {
            return match
        }
        return servers.first
    }

    /// Agent 服务地址（用所选服务器的主机 + 端口拼出）
    func baseURL(for server: SSHServer?) -> URL? {
        guard let server, server.isFilled else { return nil }
        let host = server.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, configuration.port > 0, configuration.port <= 65_535 else { return nil }
        return URL(string: "http://\(host):\(configuration.port)")
    }

    /// 是否具备云端推理条件（有服务器、有地址与令牌）
    func isReady(in servers: [SSHServer]) -> Bool {
        !token.isEmpty && baseURL(for: selectedServer(in: servers)) != nil
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        UserDefaults.standard.set(data, forKey: Self.configKey)
    }
}

// MARK: - 一键部署

/// 一键部署：把 Agent 源码通过 SSH 写到用户服务器上并以后台进程启动。
/// 脚本由纯函数生成，便于单测；执行时复用已有的 SSH 通道（SSHService）。
enum CloudDeploy {

    /// 远端目录与文件名
    static let remoteDirectory = "$HOME/.dsh"
    static let agentFileName = "dsh-agent.py"

    /// 读取 App 包内置的 Agent 源码
    static func agentSource() -> String? {
        let url = Bundle.main.url(forResource: "dsh-agent", withExtension: "py")
            ?? Bundle.main.url(forResource: "dsh-agent", withExtension: "py", subdirectory: "Resources")
        guard let url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// 部署脚本：建目录 → 写源码 → 确保 python3（国内源）→ 重启 Agent → 本机健康检查。
    ///
    /// 三个关键点（此前「部署脚本已执行，但服务没有通过自检」的原因）：
    /// 1. 命令是「整段脚本作为参数」交给远端 shell 执行的，脚本正文里出现过的字面量会出现在 shell 自己的
    ///    命令行里；所以**不能用 `pkill -f dsh-agent.py`**——它会把正在执行本脚本的 shell 一起杀掉，
    ///    后面的启动与自检都不会再跑。这里改为 pidfile 优先 + 展开后的绝对路径兜底；
    /// 2. 自检用 python3 自己请求 /health（不依赖 curl，精简镜像里常常没有 curl），并重试等待启动完成；
    /// 3. 安装 python3 统一走国内镜像（阿里云，失败再试清华），只生成本次安装用的临时源文件，
    ///    不改动服务器上已有的源配置。
    static func script(source: String, port: Int, token: String) -> String {
        """
        set -u
        DSH_DIR="\(remoteDirectory)"
        AGENT="\(remoteDirectory)/\(agentFileName)"
        # 环境组件统一下载源：apt / yum / dnf / apk 走阿里云镜像（失败回退清华），
        # 万一需要 pip 也走阿里云 PyPI 镜像
        export PIP_INDEX_URL="https://mirrors.aliyun.com/pypi/simple/"
        export PIP_TRUSTED_HOST="mirrors.aliyun.com"
        mkdir -p "$DSH_DIR/sandboxes"
        cat > "$AGENT" <<'DSH_AGENT_EOF'
        \(source)
        DSH_AGENT_EOF

        # ---- 1. 准备 python3：优先用系统已有的；缺失时用国内源安装 ----
        PY="$(command -v python3 2>/dev/null || true)"
        if [ -z "$PY" ]; then
          # python 命令存在时也要求是 python3，避免误用 python2
          if command -v python >/dev/null 2>&1 && python -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' >/dev/null 2>&1; then
            PY="$(command -v python)"
          fi
        fi
        if [ -z "$PY" ]; then
          SUDO=""; [ "$(id -u 2>/dev/null)" = "0" ] || SUDO="sudo -n"
          OSID="$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | tr -d '"' | head -n 1)"
          VER="$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | tr -d '"' | head -n 1)"
          CODENAME="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release 2>/dev/null | tr -d '"' | head -n 1)"
          ARCH="$(uname -m)"
          echo "__DSH_INSTALLING_PYTHON__"
          for M in mirrors.aliyun.com mirrors.tuna.tsinghua.edu.cn; do
            if command -v apt-get >/dev/null 2>&1 && [ -n "$CODENAME" ]; then
              case "$OSID" in
                ubuntu) DEB="deb https://$M/ubuntu $CODENAME main restricted universe multiverse"
                        UPD="deb https://$M/ubuntu $CODENAME-updates main restricted universe multiverse"
                        SEC="deb https://$M/ubuntu $CODENAME-security main restricted universe multiverse" ;;
                *)      DEB="deb https://$M/debian $CODENAME main contrib non-free"
                        UPD="deb https://$M/debian $CODENAME-updates main contrib non-free"
                        SEC="deb https://$M/debian-security $CODENAME-security main contrib non-free" ;;
              esac
              printf '%s\\n%s\\n%s\\n' "$DEB" "$UPD" "$SEC" > "$DSH_DIR/sources.cn.list"
              APT="-o Dir::Etc::sourcelist=$DSH_DIR/sources.cn.list -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0 -o Acquire::Retries=2"
              $SUDO apt-get $APT update -qq >/dev/null 2>&1
              DEBIAN_FRONTEND=noninteractive $SUDO apt-get $APT install -y -qq --no-install-recommends python3 >/dev/null 2>&1 || true
            elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
              mkdir -p "$DSH_DIR/repos.d"
              case "$OSID" in
                fedora)    BASE="https://$M/fedora/releases/$VER/Everything/$ARCH/os/" ;;
                openeuler) BASE="https://$M/openeuler/$VER/OS/$ARCH/" ;;
                *)         BASE="https://$M/centos-stream/$VER-stream/BaseOS/$ARCH/os/" ;;
              esac
              printf '[dsh-cn]\\nname=DSH CN Mirror\\nbaseurl=%s\\nenabled=1\\ngpgcheck=0\\n' "$BASE" > "$DSH_DIR/repos.d/dsh-cn.repo"
              OPT="--setopt=reposdir=$DSH_DIR/repos.d --disablerepo=* --enablerepo=dsh-cn"
              $SUDO dnf -y $OPT install python3 >/dev/null 2>&1 || $SUDO yum -y $OPT install python3 >/dev/null 2>&1 || true
            elif command -v apk >/dev/null 2>&1; then
              $SUDO apk add --no-cache --repository=https://$M/alpine/latest-stable/main --repository=https://$M/alpine/latest-stable/community python3 >/dev/null 2>&1 || true
            fi
            PY="$(command -v python3 2>/dev/null || true)"
            [ -n "$PY" ] && break
          done
        fi
        if [ -z "$PY" ]; then
          echo "__DSH_NO_PYTHON__"
          exit 0
        fi
        echo "__DSH_PYTHON_OK__ $PY"

        # ---- 2. 停掉旧实例：pidfile 优先，绝不用 pkill -f 匹配脚本名（会杀掉执行本脚本的 shell）----
        if [ -f "$DSH_DIR/agent.pid" ]; then
          OLD="$(cat "$DSH_DIR/agent.pid" 2>/dev/null || true)"
          case "$OLD" in
            ''|*[!0-9]*) ;;
            *) kill "$OLD" 2>/dev/null || true; sleep 1; kill -9 "$OLD" 2>/dev/null || true ;;
          esac
          rm -f "$DSH_DIR/agent.pid"
        fi
        for P in $(pgrep -f "$AGENT" 2>/dev/null || true); do
          [ "$P" = "$$" ] && continue
          kill "$P" 2>/dev/null || true
        done
        sleep 1

        # ---- 3. 后台启动（setsid + nohup，SSH 断开后继续运行）----
        : > "$DSH_DIR/agent.log"
        if command -v setsid >/dev/null 2>&1; then
          setsid "$PY" "$AGENT" --port \(port) --token '\(token)' --root "$DSH_DIR" >> "$DSH_DIR/agent.log" 2>&1 < /dev/null &
        else
          nohup "$PY" "$AGENT" --port \(port) --token '\(token)' --root "$DSH_DIR" >> "$DSH_DIR/agent.log" 2>&1 < /dev/null &
        fi
        echo $! > "$DSH_DIR/agent.pid"
        echo "__DSH_DEPLOY_DONE__"

        # ---- 4. 自检：用 python3 自己请求 /health（不依赖 curl），最多等 20 秒 ----
        HEALTH=""
        i=0
        while [ $i -lt 20 ]; do
          HEALTH="$("$PY" -c 'import urllib.request,sys
        try: sys.stdout.write(urllib.request.urlopen("http://127.0.0.1:\(port)/health", timeout=2).read().decode())
        except Exception: pass' 2>/dev/null || true)"
          case "$HEALTH" in
            *'"ok"'*) break ;;
          esac
          i=$((i + 1))
          sleep 1
        done
        if [ -n "$HEALTH" ]; then
          echo "$HEALTH"
        else
          echo "__DSH_HEALTH_FAILED__"
          echo "__DSH_LOG_BEGIN__"
          tail -n 30 "$DSH_DIR/agent.log" 2>/dev/null || echo "(没有日志文件)"
          echo "__DSH_LOG_END__"
        fi
        exit 0
        """
    }

    /// 部署结果判定：脚本输出里是否出现成功标记 / python 缺失标记
    static func succeeded(_ output: String) -> Bool {
        output.contains("\"ok\": true") || output.contains("\"ok\":true")
    }

    static func missingPython(_ output: String) -> Bool {
        output.contains("__DSH_NO_PYTHON__")
    }

    /// 自检失败时脚本带回的 Agent 日志尾部（供弹窗直接显示原因）
    static func logTail(_ output: String) -> String? {
        guard let begin = output.range(of: "__DSH_LOG_BEGIN__"),
              let end = output.range(of: "__DSH_LOG_END__", range: begin.upperBound..<output.endIndex)
        else { return nil }
        let tail = output[begin.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        if tail.isEmpty { return nil }
        // 弹窗里放太长会看不全，只保留末尾若干行
        let lines = tail.split(separator: "\n").suffix(12).joined(separator: "\n")
        return lines.count > 800 ? String(lines.suffix(800)) : lines
    }
}