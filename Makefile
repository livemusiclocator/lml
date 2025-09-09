usage:
	@echo "make install"
	@echo "       Install dependencies"
	@echo "make caddy"
	@echo "       Run the development server"

install:
	@lml/bin/makefile/install

caddy:
	@lml/bin/makefile/caddy
