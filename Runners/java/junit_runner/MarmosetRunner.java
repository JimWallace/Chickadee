import org.junit.platform.launcher.*;
import org.junit.platform.launcher.core.*;
import org.junit.platform.launcher.listeners.*;
import org.junit.platform.engine.discovery.DiscoverySelectors;
import org.junit.platform.engine.TestExecutionResult;
import org.junit.platform.engine.reporting.ReportEntry;

import java.io.*;
import java.util.*;
import java.util.concurrent.*;

/**
 * MarmosetRunner — thin JUnit Platform shim that runs a single test class
 * and emits a JSON array of RunnerOutcome objects to stdout.
 *
 * Usage:
 *   java -cp <classpath> MarmosetRunner <ClassName> <tier> <timeLimitSeconds>
 *
 * Output: JSON array written to stdout. Diagnostics to stderr only.
 */
public class MarmosetRunner {

    public static void main(String[] args) throws Exception {
        if (args.length < 3) {
            System.err.println("Usage: MarmosetRunner <ClassName> <tier> <timeLimitSeconds>");
            System.exit(1);
        }

        String className = args[0];
        String tier = args[1];
        int timeLimitSeconds = Integer.parseInt(args[2]);

        List<Map<String, Object>> outcomes = new ArrayList<>();

        try {
            Class<?> testClass = Class.forName(className);
            outcomes = runWithJUnitPlatform(testClass, tier, timeLimitSeconds);
        } catch (ClassNotFoundException e) {
            System.err.println("Test class not found: " + className);
            // Return empty outcomes — the shell script will handle this as an error
        }

        printJson(outcomes);
    }

    // -------------------------------------------------------------------------
    // JUnit Platform runner
    // -------------------------------------------------------------------------

    private static List<Map<String, Object>> runWithJUnitPlatform(
            Class<?> testClass, String tier, int timeLimitSeconds) throws Exception {

        List<Map<String, Object>> outcomes = new ArrayList<>();

        LauncherDiscoveryRequest request = LauncherDiscoveryRequestBuilder.request()
                .selectors(DiscoverySelectors.selectClass(testClass))
                .build();

        Launcher launcher = LauncherFactory.create();

        // Collect results via a SummaryGeneratingListener
        SummaryGeneratingListener summary = new SummaryGeneratingListener();

        // Also collect per-test timing and details
        TimingListener timing = new TimingListener(tier);

        launcher.discover(request);
        launcher.registerTestExecutionListeners(summary, timing);

        // Run with a timeout enforced from the outside
        ExecutorService executor = Executors.newSingleThreadExecutor();
        Future<?> future = executor.submit(() -> launcher.execute(request));

        try {
            future.get(timeLimitSeconds, TimeUnit.SECONDS);
        } catch (TimeoutException e) {
            future.cancel(true);
            // Mark all tests that did not finish as timeout
            timing.markRemainingAsTimeout(timeLimitSeconds * 1000L);
        } finally {
            executor.shutdownNow();
        }

        return timing.getOutcomes();
    }

    // -------------------------------------------------------------------------
    // Listener that records per-test results
    // -------------------------------------------------------------------------

    static class TimingListener implements TestExecutionListener {

        private final String tier;
        private final Map<String, Long> startTimes = new LinkedHashMap<>();
        private final List<Map<String, Object>> outcomes = new ArrayList<>();
        private final Set<String> finished = new HashSet<>();

        TimingListener(String tier) {
            this.tier = tier;
        }

        @Override
        public void executionStarted(TestIdentifier id) {
            if (id.isTest()) {
                startTimes.put(id.getUniqueId(), System.currentTimeMillis());
            }
        }

        @Override
        public void executionFinished(TestIdentifier id, TestExecutionResult result) {
            if (!id.isTest()) return;

            long start = startTimes.getOrDefault(id.getUniqueId(), System.currentTimeMillis());
            long elapsed = System.currentTimeMillis() - start;
            finished.add(id.getUniqueId());

            Map<String, Object> outcome = new LinkedHashMap<>();
            outcome.put("testName", id.getDisplayName().replaceAll("\\(\\)$", ""));
            outcome.put("testClass", extractClassName(id));
            outcome.put("tier", tier);
            outcome.put("executionTimeMs", elapsed);
            outcome.put("memoryUsageBytes", null);

            switch (result.getStatus()) {
                case SUCCESSFUL:
                    outcome.put("status", "pass");
                    outcome.put("shortResult", "passed");
                    outcome.put("longResult", null);
                    break;
                case FAILED:
                    Throwable thrown = result.getThrowable().orElse(null);
                    if (thrown != null && isAssertionError(thrown)) {
                        outcome.put("status", "fail");
                        outcome.put("shortResult", firstLine(thrown.getMessage()));
                        outcome.put("longResult", stackTrace(thrown));
                    } else {
                        outcome.put("status", "error");
                        outcome.put("shortResult", thrown != null ? firstLine(thrown.toString()) : "unknown error");
                        outcome.put("longResult", thrown != null ? stackTrace(thrown) : null);
                    }
                    break;
                case ABORTED:
                    outcome.put("status", "error");
                    outcome.put("shortResult", "test aborted");
                    outcome.put("longResult", result.getThrowable().map(MarmosetRunner::stackTrace).orElse(null));
                    break;
            }

            outcomes.add(outcome);
        }

        void markRemainingAsTimeout(long elapsedMs) {
            for (Map.Entry<String, Long> entry : startTimes.entrySet()) {
                if (!finished.contains(entry.getKey())) {
                    Map<String, Object> outcome = new LinkedHashMap<>();
                    // Use a generic name for tests that never started reporting
                    outcome.put("testName", "unknown");
                    outcome.put("testClass", null);
                    outcome.put("tier", tier);
                    outcome.put("status", "timeout");
                    outcome.put("shortResult", "Exceeded time limit of " + (elapsedMs / 1000) + "s");
                    outcome.put("longResult", null);
                    outcome.put("executionTimeMs", elapsedMs);
                    outcome.put("memoryUsageBytes", null);
                    outcomes.add(outcome);
                }
            }
        }

        List<Map<String, Object>> getOutcomes() {
            return outcomes;
        }

        private String extractClassName(TestIdentifier id) {
            // Unique IDs look like: [engine:junit-jupiter]/[class:PublicTests]/[method:testFoo()]
            String uid = id.getUniqueId();
            int classStart = uid.indexOf("[class:");
            if (classStart < 0) return null;
            int classEnd = uid.indexOf(']', classStart);
            if (classEnd < 0) return null;
            return uid.substring(classStart + 7, classEnd);
        }
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    private static boolean isAssertionError(Throwable t) {
        return t instanceof AssertionError
                || t.getClass().getName().contains("AssertionFailedError")
                || t.getClass().getName().contains("ComparisonFailure");
    }

    private static String firstLine(String s) {
        if (s == null) return "null";
        int nl = s.indexOf('\n');
        return nl < 0 ? s : s.substring(0, nl);
    }

    private static String stackTrace(Throwable t) {
        StringWriter sw = new StringWriter();
        t.printStackTrace(new PrintWriter(sw));
        return sw.toString().trim();
    }

    // -------------------------------------------------------------------------
    // Minimal JSON serialiser (no external library dependency)
    // -------------------------------------------------------------------------

    private static void printJson(List<Map<String, Object>> outcomes) {
        StringBuilder sb = new StringBuilder();
        sb.append("[\n");
        for (int i = 0; i < outcomes.size(); i++) {
            sb.append("  ").append(mapToJson(outcomes.get(i)));
            if (i < outcomes.size() - 1) sb.append(",");
            sb.append("\n");
        }
        sb.append("]");
        System.out.println(sb);
    }

    private static String mapToJson(Map<String, Object> map) {
        StringBuilder sb = new StringBuilder("{");
        boolean first = true;
        for (Map.Entry<String, Object> e : map.entrySet()) {
            if (!first) sb.append(", ");
            first = false;
            sb.append(jsonString(e.getKey())).append(": ").append(jsonValue(e.getValue()));
        }
        sb.append("}");
        return sb.toString();
    }

    private static String jsonValue(Object v) {
        if (v == null) return "null";
        if (v instanceof Boolean) return v.toString();
        if (v instanceof Number) return v.toString();
        if (v instanceof String) return jsonString((String) v);
        return "null";
    }

    private static String jsonString(String s) {
        return "\"" + s
                .replace("\\", "\\\\")
                .replace("\"", "\\\"")
                .replace("\n", "\\n")
                .replace("\r", "\\r")
                .replace("\t", "\\t")
                + "\"";
    }
}
