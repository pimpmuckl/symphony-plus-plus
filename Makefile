.PHONY: all ci ci-fast ci-static ci-test ci-dialyzer ci-coverage ci-hygiene ci-full

all ci ci-fast ci-static ci-test ci-dialyzer ci-coverage ci-hygiene ci-full:
	$(MAKE) -C elixir $@
