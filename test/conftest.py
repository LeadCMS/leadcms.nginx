def pytest_terminal_summary(terminalreporter):
    """Reminds the developer that the docker stack is still up.

    It is left running on purpose so the next run costs seconds instead of a
    rebuild; see test/test_integration.py.
    """
    if terminalreporter.stats:
        terminalreporter.write_line(
            "integration stack left running for fast re-runs — stop it with: "
            "bash test/run-integration-tests.sh --teardown"
        )
