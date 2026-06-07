# Use an official Python runtime as a parent image.
# NOTE: 3.12 (not 3.9) — the code uses PEP 604 `X | None` syntax (Python 3.10+).
FROM python:3.12-slim

# Set the working directory in the container
WORKDIR /app

# Copy the requirements file into the container
COPY requirements.txt .

# Install any needed packages specified in requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of the application code into the container
COPY . .

# Expose port 8000 for the FastAPI application
EXPOSE 8000

# SUPABASE_URL default points at a locally-running Supabase CLI stack.
# SUPABASE_SERVICE_ROLE_KEY and MAPBOX_ACCESS_TOKEN are REQUIRED at runtime and
# must be supplied via docker-compose / .env (main.py and safenav.py hard-fail
# without them). Never bake real keys into the image.
ENV SUPABASE_URL=http://host.docker.internal:54321

# Command to run the application
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
