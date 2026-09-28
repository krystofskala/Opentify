FROM python:3.12-slim

WORKDIR /app

# ffmpeg -- YoutubeProvider (app/providers.py) na něm staví přes yt-dlp
# postprocessor `FFmpegExtractAudio`; bez něj fallback ingestion cesta
# padá s "ffmpeg not found" až za běhu, ne při buildu.
RUN apt-get update \
    && apt-get install --no-install-recommends -y ffmpeg \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
