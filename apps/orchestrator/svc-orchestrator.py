"""Dev launcher: names sys.argv[0] so amp-instrument/Traceloop sets a distinct
OTEL service.name (Traceloop uses app_name=sys.argv[0], which overrides
OTEL_SERVICE_NAME). Guarded for uvicorn --reload subprocess spawning.
"""
import sys
sys.path.insert(0, "/app")  # running by path drops /app from sys.path; restore it

import uvicorn

if __name__ == "__main__":
    uvicorn.run(
        "orchestrator.main:create_app", factory=True,
        host="0.0.0.0", port=8080,
        reload=True, reload_dirs=["/app/orchestrator", "/app/common"],
    )
