# SysInfo 构建入口（K30，M0 设计 §9）。
# 用法：make build | run | test | test-hw | cli | remote-cli | release | measure

.DEFAULT_GOAL := help

PROJECT        := SysInfo.xcodeproj
SCHEME         := SysInfo
DERIVED_DATA   := build/DerivedData
PACKAGE_PATH   := Packages/SysKit
BUILD_NUMBER   := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
# git 短哈希，工作区有未提交改动时加 -dirty；Debug 版「关于」页显示（K30）。
GIT_COMMIT     := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)$(shell git diff --quiet HEAD 2>/dev/null || echo -dirty)

DEBUG_APP      := $(DERIVED_DATA)/Build/Products/Debug/SysInfo.app
RELEASE_APP    := $(DERIVED_DATA)/Build/Products/Release/SysInfo.app
DEV_BUNDLE_ID  := zone.lyl.sysinfo.dev

# 远端对照机（M4 Pro Mac mini，D28）；远端只在 /tmp 下写文件（M0 设计 §7、D18）。
# 地址不进库（D77）：写在 Config/remote.local.mk（已被 .gitignore 忽略，格式见 Config/remote.local.mk.example），
# 也可以临时覆盖：make remote-cli REMOTE_HOST=user@host
-include Config/remote.local.mk
REMOTE_HOST    ?=
REMOTE_DIR     := /tmp/sysinfo-remote
# SwiftPM 默认往家目录写 manifest 缓存、配置和安全目录（~/Library/Caches/org.swift.swiftpm、
# ~/Library/org.swift.swiftpm、~/.swiftpm 下的链接）。显式指定 --cache-path 等之后它仍会重建
# ~/.swiftpm/security 链接，改 HOME 也没用（它按 NSHomeDirectory 取家目录），所以另设 CFFIXED_USER_HOME
# 把家目录整个换到 REMOTE_DIR/home（2026-09-29 在当时的对照机 Mac Studio 上实测：真实家目录下不再有任何改动）。
# 构建目录本来就在 REMOTE_DIR/SysKit/.build；TMPDIR 也指过去，xcrun 等工具按它写临时缓存。
REMOTE_SWIFTPM := --cache-path $(REMOTE_DIR)/swiftpm/cache --config-path $(REMOTE_DIR)/swiftpm/config \
	--security-path $(REMOTE_DIR)/swiftpm/security --manifest-cache local
REMOTE_ENV     := CFFIXED_USER_HOME=$(REMOTE_DIR)/home HOME=$(REMOTE_DIR)/home TMPDIR=$(REMOTE_DIR)/tmp
# 非交互：密钥登录失败时直接报错，不卡在密码提示上。
SSH            := ssh -o BatchMode=yes -o ConnectTimeout=10

# 传给 app（run）或 sysinfo-cli（cli、remote-cli）的参数，例如 make cli ARGS="cpu --count 5"
ARGS ?=

XCODEBUILD = xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS,arch=arm64' \
	-derivedDataPath $(DERIVED_DATA) \
	CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) SYSINFO_GIT_COMMIT=$(GIT_COMMIT)

# 私有 C 层隔离检查的范围（D05、D23）：能经依赖闭包看到 CSysPrivate、但不允许 import 它的源码目录。
# app 的 App/ 另由 Xcode 的「Check private imports」构建阶段检查。
PRIVATE_IMPORT_GUARDED := App Widgets WidgetShared $(PACKAGE_PATH)/Sources/sysinfo-cli $(PACKAGE_PATH)/Sources/SysStore

.PHONY: require-remote-host help build run stop test test-hw cli remote-sync remote-cli remote-test remote-app-build remote-app-run remote-app-shot remote-app-clean remote-measure release dist measure strings install clean check-private-imports check-leaks test-scripts

help:
	@echo "SysInfo Makefile 目标："
	@echo "  build       构建 Debug 版 SysInfo Dev（$(DEV_BUNDLE_ID)）"
	@echo "  run         构建并启动 Debug 版；先结束已在运行的 SysInfo Dev（只结束它）。ARGS 传给 app"
	@echo "  stop        结束正在运行的 SysInfo Dev"
	@echo "  test        运行 SysKit 单元测试（跳过 .hardware 标签）"
	@echo "  test-hw     运行 SysKit 单元测试，包括硬件测试"
	@echo "  cli         构建并运行 sysinfo-cli，ARGS 为子命令与选项"
	@echo "  remote-cli  在对照机（$(REMOTE_HOST)）上构建并运行 sysinfo-cli（只写远端 $(REMOTE_DIR)）"
	@echo "  remote-test 在对照机上运行 SysKit 单元测试，包括硬件测试（只写远端 $(REMOTE_DIR)）"
	@echo "  remote-measure  在对照机上做同样的开销测量，结果追加到 docs/perf/cpu.md，之后清场（D39）"
	@echo "  remote-app-build / remote-app-run / remote-app-shot / remote-app-clean"
	@echo "              在对照机上构建、启动、截图、清场 Debug 版 app（D39；run 的 ARGS 传给 app，shot 用 OUT= 与 POS=）"
	@echo "  release     构建 Release 版 SysInfo（zone.lyl.sysinfo）"
	@echo "  dist        打可分发的 Release 包到 build/dist（签名；有公证凭据时公证并 staple，D74）"
	@echo "  measure     运行 scripts/measure-overhead.sh 测量自身开销（Stats 在运行时拒绝执行）"
	@echo "  strings     构建后把代码里的文案同步进 App/Localizable.xcstrings"
	@echo "  check-private-imports  检查 app、sysinfo-cli 与 SysStore 没有引用 CSysPrivate（test、cli 会先跑它）"
	@echo "  check-leaks 检查已跟踪文件里没有内网地址、家目录、设备标识、卷名等（D77，test、test-hw 会先跑它）"
	@echo "  test-scripts  运行 check-private-imports 的回归样例（test、test-hw 会先跑它）"
	@echo "  clean       删除 build/ 与 SwiftPM 构建目录"

build:
	$(XCODEBUILD) -configuration Debug build

release:
	$(XCODEBUILD) -configuration Release build

# 只结束可执行文件路径是本仓库 Debug 产物的 SysInfo Dev（D18：不碰 Release 版、Stats 或其他程序）。
stop:
	@scripts/stop-dev.sh "$(abspath $(DEBUG_APP))"

run: build stop
	open "$(DEBUG_APP)" $(if $(ARGS),--args $(ARGS))

# D77：公开仓库防泄漏（私网地址、家目录、UUID/MAC、卷名、签名真名、本地黑名单）。
check-leaks:
	@scripts/check-leaks.sh

check-private-imports:
	@scripts/check-private-imports.sh $(PRIVATE_IMPORT_GUARDED)

# 私有层隔离检查是 D23 的唯一防线，它自己的回归样例随单元测试一起跑。
test-scripts:
	@scripts/test-check-private-imports.sh

test: test-scripts check-private-imports check-leaks
	swift test --package-path $(PACKAGE_PATH)

test-hw: test-scripts check-private-imports check-leaks
	SYSINFO_HW_TESTS=1 swift test --package-path $(PACKAGE_PATH)

cli: check-private-imports
	swift run --package-path $(PACKAGE_PATH) sysinfo-cli $(ARGS)

require-remote-host:
	@if [ -z "$(REMOTE_HOST)" ]; then \
		echo "没有设置 REMOTE_HOST：在 Config/remote.local.mk 里写 REMOTE_HOST := user@host（见 .example），或在命令行传入。" >&2; exit 1; fi

# 把 Packages/SysKit 同步到远端 /tmp/sysinfo-remote/SysKit（保留远端 .build 以便增量构建）。
remote-sync: check-private-imports require-remote-host
	$(SSH) $(REMOTE_HOST) 'mkdir -p $(REMOTE_DIR)/tmp $(REMOTE_DIR)/home'
	rsync -a --delete --exclude .build --exclude .swiftpm -e "$(SSH)" $(PACKAGE_PATH)/ $(REMOTE_HOST):$(REMOTE_DIR)/SysKit/

# 在远端 swift run -c release sysinfo-cli，ARGS 原样透传，例如 make remote-cli ARGS="cpu --count 5 --json"
remote-cli: remote-sync
	$(SSH) $(REMOTE_HOST) 'cd $(REMOTE_DIR)/SysKit && $(REMOTE_ENV) swift run -c release $(REMOTE_SWIFTPM) sysinfo-cli $(ARGS)'

# 在远端跑单元测试，包括硬件测试（D25：每个模块验收要附两台机器的结果）。
remote-test: test-scripts remote-sync
	$(SSH) $(REMOTE_HOST) 'cd $(REMOTE_DIR)/SysKit && $(REMOTE_ENV) SYSINFO_HW_TESTS=1 swift test $(REMOTE_SWIFTPM)'

# D39：对照机上的截图自查。启动总是带 --factory-defaults；用完 remote-app-clean 清场。
remote-app-build: check-private-imports require-remote-host
	REMOTE_HOST=$(REMOTE_HOST) scripts/remote-app.sh build

remote-app-run: require-remote-host
	REMOTE_HOST=$(REMOTE_HOST) scripts/remote-app.sh run $(ARGS)

remote-app-shot: require-remote-host
	REMOTE_HOST=$(REMOTE_HOST) scripts/remote-app.sh shot "$(OUT)" $(POS)

remote-app-clean: require-remote-host
	REMOTE_HOST=$(REMOTE_HOST) scripts/remote-app.sh clean

# CPU 模块设计 §10：在对照机上做同样的四档测量（远端检测到 Stats 时同样拒绝执行），结果追加到 docs/perf/cpu.md，之后清场（D39）。
remote-measure: check-private-imports require-remote-host
	REMOTE_HOST=$(REMOTE_HOST) scripts/remote-app.sh measure

measure:
	@if [ ! -x scripts/measure-overhead.sh ]; then \
		echo "scripts/measure-overhead.sh 尚未实现：开销测量脚本在 M0 后续阶段加入（M0 设计 §9、K26）。" >&2; \
		exit 1; \
	fi
	scripts/measure-overhead.sh

# 把编译器从代码里提取的文案（.stringsdata）同步进 String Catalog（D23）。xcodebuild 不会自动回写 .xcstrings。
strings: build
	@for pair in "SysInfo:App" "SysInfoWidgets:Widgets"; do \
		target=$${pair%%:*}; dir=$${pair##*:}; \
		files=$$(find $(DERIVED_DATA)/Build/Intermediates.noindex/SysInfo.build/Debug/$$target.build -name '*.stringsdata' 2>/dev/null); \
		if [ -z "$$files" ]; then echo "没有找到 $$target 的 .stringsdata，请先 make build" >&2; exit 1; fi; \
		args=""; for f in $$files; do args="$$args --stringsdata $$f"; done; \
		xcrun xcstringstool sync $$dir/Localizable.xcstrings $$args || exit 1; \
		echo "已同步 $$dir/Localizable.xcstrings"; \
	done

# D74：可分发的 Release 包（签名；设了 NOTARY_PROFILE 或 API key 环境变量时再公证并 staple），产物在 build/dist。
# CI 推 v* tag 时走同一个脚本并发布到 GitHub Releases。
dist:
	scripts/build-release.sh

# 发布改由 CI 出包、各机自行下载（D74），本机不再提供 install。
install:
	@echo "不提供 make install：推 v* tag 后由 CI 发布，从 GitHub Releases 下载安装（D74）。本机打包用 make dist。" >&2
	@exit 1

clean:
	rm -rf build $(PACKAGE_PATH)/.build
