# Leiden Risk User Identification - Docker Image
# Usage:
#   docker build -t leiden-risk .
#   docker run -p 8766:8766 -v $(pwd)/data:/app/data leiden-risk
#
# Or use docker-compose:
#   docker compose up

FROM python:3.11-slim

# System deps for igraph, matplotlib, xgboost compilation
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc g++ libxml2-dev libgmp-dev libffi-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python dependencies first (better Docker layer caching)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
RUN pip install --no-cache-dir jupyter nbformat

# Copy all code (data/ is excluded via .dockerignore, mounted as volume)
COPY notebooks/ notebooks/
COPY tools/ tools/
COPY docs/ docs/
COPY sql/ sql/
COPY tableau/ tableau/
COPY README.md ./

# Data directory will be mounted as volume
# - data/flight_feature_detail_8.19-90days.csv  (raw input, 269MB)
# - data/model_output/                          (all model outputs, ~700MB)
VOLUME ["/app/data"]

# Expose community server port
EXPOSE 8766

# Run community server with Docker-friendly settings
CMD ["python", "tools/community_server.py", "--host", "0.0.0.0", "--port", "8766", "--no-browser"]

