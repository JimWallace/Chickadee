### Changed

- **One log capture and one forwarding database for the API tests.** Thirteen private capturing log handlers become `CapturedLog` (`Tests/APITests/LogCapture.swift`) and seven private forwarding Fluent databases become `ForwardingTestDatabase`, which re-wraps its transactions and connections so a refusal rule reaches nested work.
