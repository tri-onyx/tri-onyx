FROM elixir:1.18-otp-27-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
  git \
  ca-certificates \
  curl \
  inotify-tools \
  build-essential \
  && install -m 0755 -d /etc/apt/keyrings \
  && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list \
  && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends docker-ce-cli gh \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Piper TTS + ffmpeg back the Speak tool (TriOnyx.Speech). The piper release
# tarball extracts to /opt/piper (binary + espeak-ng data); Norwegian and
# English voice models are fetched from the piper-voices repo on Hugging Face.
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg \
  && apt-get clean && rm -rf /var/lib/apt/lists/* \
  && curl -fsSL https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_x86_64.tar.gz \
     | tar -xz -C /opt \
  && mkdir -p /opt/piper/voices \
  && curl -fsSL -o /opt/piper/voices/no_NO-talesyntese-medium.onnx \
     "https://huggingface.co/rhasspy/piper-voices/resolve/main/no/no_NO/talesyntese/medium/no_NO-talesyntese-medium.onnx" \
  && curl -fsSL -o /opt/piper/voices/no_NO-talesyntese-medium.onnx.json \
     "https://huggingface.co/rhasspy/piper-voices/resolve/main/no/no_NO/talesyntese/medium/no_NO-talesyntese-medium.onnx.json" \
  && curl -fsSL -o /opt/piper/voices/en_US-lessac-medium.onnx \
     "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx" \
  && curl -fsSL -o /opt/piper/voices/en_US-lessac-medium.onnx.json \
     "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json"

RUN mix local.hex --force && mix local.rebar --force

WORKDIR /app

CMD ["mix", "test"]
