.PHONY: build test test-extension clean fmt lint install deb

build:
	dune build @all

test:
	dune runtest

test-extension: build
	cd extension && npm test

clean:
	dune clean

fmt:
	dune fmt

lint:
	dune build @check

install:
	dune install

VERSION ?= 0.0.0

deb:
	dune build bin/server/main.exe bin/client/main.exe extension/main.bc.js
	@mkdir -p _build/deb
	# -- url-router (daemon) package
	$(eval DEB_ROUTER := _build/deb/url-router_$(VERSION))
	@rm -rf $(DEB_ROUTER)
	@mkdir -p $(DEB_ROUTER)/DEBIAN
	@mkdir -p $(DEB_ROUTER)/usr/bin
	@mkdir -p $(DEB_ROUTER)/usr/lib/systemd/system
	@cp _build/default/bin/server/main.exe $(DEB_ROUTER)/usr/bin/url-router
	@echo "Package: url-router" > $(DEB_ROUTER)/DEBIAN/control
	@echo "Version: $(VERSION)" >> $(DEB_ROUTER)/DEBIAN/control
	@echo "Section: net" >> $(DEB_ROUTER)/DEBIAN/control
	@echo "Priority: optional" >> $(DEB_ROUTER)/DEBIAN/control
	@echo "Architecture: amd64" >> $(DEB_ROUTER)/DEBIAN/control
	@echo "Depends:" >> $(DEB_ROUTER)/DEBIAN/control
	@echo "Maintainer: url-router maintainers" >> $(DEB_ROUTER)/DEBIAN/control
	@echo "Description: Multi-tenant URL routing daemon" >> $(DEB_ROUTER)/DEBIAN/control
	@echo "[Unit]" > $(DEB_ROUTER)/usr/lib/systemd/system/url-router.service
	@echo "Description=URL Router daemon" >> $(DEB_ROUTER)/usr/lib/systemd/system/url-router.service
	@echo "After=network.target" >> $(DEB_ROUTER)/usr/lib/systemd/system/url-router.service
	@echo "" >> $(DEB_ROUTER)/usr/lib/systemd/system/url-router.service
	@echo "[Service]" >> $(DEB_ROUTER)/usr/lib/systemd/system/url-router.service
	@echo "Type=simple" >> $(DEB_ROUTER)/usr/lib/systemd/system/url-router.service
	@echo "ExecStart=/usr/bin/url-router" >> $(DEB_ROUTER)/usr/lib/systemd/system/url-router.service
	@echo "Restart=on-failure" >> $(DEB_ROUTER)/usr/lib/systemd/system/url-router.service
	@echo "RuntimeDirectory=url-router" >> $(DEB_ROUTER)/usr/lib/systemd/system/url-router.service
	@echo "" >> $(DEB_ROUTER)/usr/lib/systemd/system/url-router.service
	@echo "[Install]" >> $(DEB_ROUTER)/usr/lib/systemd/system/url-router.service
	@echo "WantedBy=multi-user.target" >> $(DEB_ROUTER)/usr/lib/systemd/system/url-router.service
	@dpkg-deb --root-owner-group --build $(DEB_ROUTER) _build/deb/url-router_$(VERSION)_amd64.deb
	# -- url-router-client package
	$(eval DEB_CLIENT := _build/deb/url-router-client_$(VERSION))
	@rm -rf $(DEB_CLIENT)
	@mkdir -p $(DEB_CLIENT)/DEBIAN
	@mkdir -p $(DEB_CLIENT)/usr/bin
	@mkdir -p $(DEB_CLIENT)/etc/chromium/native-messaging-hosts
	@mkdir -p $(DEB_CLIENT)/etc/opt/edge/native-messaging-hosts
	@mkdir -p $(DEB_CLIENT)/usr/share/url-router/extension
	@cp _build/default/bin/client/main.exe $(DEB_CLIENT)/usr/bin/url-router-client
	@echo '{"name":"url_router","description":"URL Router native messaging host","path":"/usr/bin/url-router-client","type":"stdio","allowed_origins":["chrome-extension://url-router/"]}' > $(DEB_CLIENT)/etc/chromium/native-messaging-hosts/url_router.json
	@cp $(DEB_CLIENT)/etc/chromium/native-messaging-hosts/url_router.json $(DEB_CLIENT)/etc/opt/edge/native-messaging-hosts/url_router.json
	@cp extension/manifest.json $(DEB_CLIENT)/usr/share/url-router/extension/
	@cp extension/popup.html $(DEB_CLIENT)/usr/share/url-router/extension/
	@cp extension/popup.js $(DEB_CLIENT)/usr/share/url-router/extension/
	@cp _build/default/extension/main.bc.js $(DEB_CLIENT)/usr/share/url-router/extension/main.js
	@cp -r extension/icons $(DEB_CLIENT)/usr/share/url-router/extension/
	@echo "Package: url-router-client" > $(DEB_CLIENT)/DEBIAN/control
	@echo "Version: $(VERSION)" >> $(DEB_CLIENT)/DEBIAN/control
	@echo "Section: net" >> $(DEB_CLIENT)/DEBIAN/control
	@echo "Priority: optional" >> $(DEB_CLIENT)/DEBIAN/control
	@echo "Architecture: amd64" >> $(DEB_CLIENT)/DEBIAN/control
	@echo "Depends:" >> $(DEB_CLIENT)/DEBIAN/control
	@echo "Maintainer: url-router maintainers" >> $(DEB_CLIENT)/DEBIAN/control
	@echo "Description: URL Router native messaging bridge and CLI" >> $(DEB_CLIENT)/DEBIAN/control
	@dpkg-deb --root-owner-group --build $(DEB_CLIENT) _build/deb/url-router-client_$(VERSION)_amd64.deb
	@echo "Built: _build/deb/url-router_$(VERSION)_amd64.deb"
	@echo "Built: _build/deb/url-router-client_$(VERSION)_amd64.deb"
