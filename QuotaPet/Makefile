.PHONY: app run demo dump check previews relay-previews install release clean

APP := build/QuotaPet.app

# 关掉正在运行的 QuotaPet，并等它真正退出（最多 5 秒）：刚杀掉就 open，系统还没把旧进程清掉，open 会报 error -600
QUIT = pkill -x QuotaPet; for i in $$(seq 25); do pgrep -x QuotaPet >/dev/null || break; sleep 0.2; done
# 打开 App；刚换掉 App 文件时系统偶尔还没认出新的，失败了等一秒再试一次。用法：$(call OPEN,App 路径,参数)
OPEN = open $(1) $(2) || { sleep 1; open $(1) $(2); }

# 打包成 build/QuotaPet.app
app:
	./scripts/build-app.sh

# 打包并启动（先关掉正在运行的）
run: app
	@$(QUIT)
	$(call OPEN,$(APP))

# 演示模式：假数据，75 秒看完宠物的所有状态
demo: app
	@$(QUIT)
	$(call OPEN,$(APP),--args --demo)

# 在终端打印当前额度（和 usage_lab.py 对账用）
dump:
	swift run -c release QuotaPet --dump

# 自检
check:
	swift run QuotaPetChecks

# 把宠物、菜单栏、面板渲染成 PNG 到 build/previews
previews:
	swift run -c release QuotaPet --render-previews build/previews

# 双宠接力 + 面板顶部信息的三张预览图（只用合成数据）到 build/previews
relay-previews:
	swift run -c release QuotaPet --render-relay-previews build/previews

# 装到 ~/Applications 并打开「开机自动启动」：以后一打开 Claude 宠物就会出现
install: app
	@$(QUIT)
	mkdir -p ~/Applications
	rm -rf ~/Applications/QuotaPet.app
	cp -R $(APP) ~/Applications/
	$(call OPEN,~/Applications/QuotaPet.app,--args --enable-login-item)

# 发 GitHub Release 用：Apple 芯片 + Intel 通用版，压成 build/QuotaPet-<版本>.zip（版本号取 Info.plist）
VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
# 打包前：版本号要读得出来，QuotaPet/ 下不能有没提交的改动（发出去的包要和某次提交对得上）。
# 打完包再查一遍最终的压缩包（解开来查文件名和内容，规则和提交钩子共用 ../.githooks/privacy-scan.sh）：
# 不能有本机绝对路径、真实数据、截图、不在清单里的文件（仓库是公开的，Release 谁都能下载）
release:
	@if [ -z "$(VERSION)" ]; then echo "❌ 读不出 Resources/Info.plist 里的版本号"; exit 1; fi
	@if [ -n "$$(git status --porcelain -- .)" ]; then git status --short -- .; echo "❌ 上面这些改动还没提交，先提交再打包"; exit 1; fi
	UNIVERSAL=1 ./scripts/build-app.sh
	rm -f build/QuotaPet-$(VERSION).zip
	ditto -c -k --norsrc --noextattr --keepParent $(APP) build/QuotaPet-$(VERSION).zip
	@./scripts/check-release-archive.sh build/QuotaPet-$(VERSION).zip
	shasum -a 256 build/QuotaPet-$(VERSION).zip

clean:
	rm -rf .build build
