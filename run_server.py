"""VIGIL Application Server Launcher.
Runs the FastAPI backend and scientific user interface.
"""
import sys
import uvicorn
from vigil.config import JOBS_DIR

def main():
    JOBS_DIR.mkdir(parents=True, exist_ok=True)
    port = 8000
    host = "127.0.0.1"
    print("=" * 70)
    print(" VIGIL: Ground-Based Optical Detection and Tracking of Orbital Debris")
    print(" NASA-Inspired Scientific Interface & MATLAB Execution Boundary")
    print(f" Server starting at http://{host}:{port}")
    print("=" * 70)
    uvicorn.run("vigil.api:app", host=host, port=port, reload=False)

if __name__ == "__main__":
    main()
