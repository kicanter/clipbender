# Thin wrapper over build.sh, providing the conventional `make` interface that
# distro packagers and contributors expect. All real logic lives in build.sh.
#
#   make            # optimized + stripped build (both binaries)
#   make dev        # unoptimized build (-vet -warnings-as-errors)
#   make debug      # debug build (-debug -sanitize:address)
#   make release    # same as `make`
#   make test       # run all tests
#   make protocols  # regenerate Wayland protocol bindings from XML
#   make install    # honors PREFIX / DESTDIR, e.g. `make install PREFIX=/usr DESTDIR=pkg`
#   make uninstall  # remove installed files (honors PREFIX / DESTDIR)
#   make clean      # remove build artifacts
#   make distclean  # clean + remove the generated vended artifacts
#
# Build a single package with PKG=daemon or PKG=client, e.g. `make dev PKG=daemon`.
# Test a single package with PKG=<name>, e.g. `make test PKG=libclipbender`.

# Exported so build.sh picks them up from the environment.
export PREFIX
export DESTDIR
export FLAGS

all: release

dev debug release:
	./build.sh $@ $(PKG)

test:
	./build.sh test $(PKG)

protocols clean distclean install uninstall:
	./build.sh $@

.PHONY: all dev debug release test protocols clean distclean install uninstall
