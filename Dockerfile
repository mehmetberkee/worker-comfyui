# Stage 1: Base image with common dependencies
FROM nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04 as base

# Prevents prompts from packages asking for user input during installation
ENV DEBIAN_FRONTEND=noninteractive
# Prefer binary wheels over source distributions for faster pip installations
ENV PIP_PREFER_BINARY=1
# Ensures output from python is printed immediately to the terminal without buffering
ENV PYTHONUNBUFFERED=1 
# Speed up some cmake builds
ENV CMAKE_BUILD_PARALLEL_LEVEL=8

# Install Python, git and other necessary tools
RUN apt-get update && apt-get install -y \
    python3.10 python3-pip git wget \
    libgl1 \
    libglib2.0-0 \
    libsm6 libxext6 libxrender1 \
 && ln -sf /usr/bin/python3.10 /usr/bin/python \
 && ln -sf /usr/bin/pip3 /usr/bin/pip


# Clean up to reduce image size
RUN apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*

# Install comfy-cli
RUN pip install comfy-cli

# Install ComfyUI
RUN /usr/bin/yes | comfy --workspace /comfyui install --cuda-version 11.8 --nvidia --version 0.3.26

# Change working directory to ComfyUI
WORKDIR /comfyui

###############################################################################
# ⬇︎  BU BLOĞU “WORKDIR /comfyui” SATIRINDAN SONRA EKLEYİN  ⬇︎
###############################################################################

# — 1) Klonlanacak node repo’larının listesi
ARG CUSTOM_NODE_REPOS="\
cg-use-everywhere=https://github.com/chrisgoringe/cg-use-everywhere.git \
comfy-image-saver=https://github.com/farizrifqi/ComfyUI-Image-Saver.git \
comfyui-kjnodes=https://github.com/kijai/ComfyUI-KJNodes.git \
pulid-comfyui=https://github.com/cubiq/PuLID_ComfyUI.git \
rgthree-comfy=https://github.com/rgthree/rgthree-comfy.git \
"

# — 2) Hepsini /comfyui/custom_nodes altına klonla
RUN set -eux; \
    mkdir -p /comfyui/custom_nodes; \
    for entry in $CUSTOM_NODE_REPOS; do \
        name="${entry%%=*}"; repo="${entry#*=}"; \
        echo ">>> Cloning $repo -> $name"; \
        git clone --depth 1 "$repo" "/comfyui/custom_nodes/$name"; \
    done

RUN pip install --no-cache-dir \
    packaging filetype pillow
# — 3) requirements.txt bulunan klasörleri bulup kur
RUN find /comfyui/custom_nodes -name requirements.txt -print0 \
    | xargs -0 -I{} pip install --no-cache-dir -r {}

###############################################################################
# ⬆︎  EK BLOK BİTTİ  ⬆︎
###############################################################################


# ---------------- PuLID için Gerekli Bağımlılıkları Kur ------------------

# facexlib için gerekli olabilecek sistem kütüphanesi
RUN apt-get update && apt-get install -y --no-install-recommends unzip libstdc++6 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# 1. facexlib'i kur
RUN pip install --no-cache-dir --use-pep517 facexlib

# 2. insightface'in belirli sürümünü (0.7.3) ve onnxruntime-gpu'yu PyPI'dan kur
#    Not: CUDA ortamında olduğumuz için onnxruntime-gpu kullanıyoruz.
RUN pip install --no-cache-dir insightface==0.7.3 onnxruntime-gpu

# --------------------------------------------------------------------------
ENV INSIGHTFACE_MODELS_DIR=/comfyui/models/insightface/models
RUN set -eux; \
    mkdir -p ${INSIGHTFACE_MODELS_DIR}; \
    wget -nv -O /tmp/antelopev2.zip \
        https://github.com/deepinsight/insightface/releases/download/v0.7/antelopev2.zip; \
    unzip -q /tmp/antelopev2.zip -d ${INSIGHTFACE_MODELS_DIR}; \
    # antelopev2.zip bazen iç içe klasörle gelir, gerekirse düzleştir
    if [ -d ${INSIGHTFACE_MODELS_DIR}/antelopev2/antelopev2 ]; then \
        mv ${INSIGHTFACE_MODELS_DIR}/antelopev2/antelopev2/* \
            ${INSIGHTFACE_MODELS_DIR}/antelopev2/ && \
        rmdir ${INSIGHTFACE_MODELS_DIR}/antelopev2/antelopev2; \
    fi && \
    rm -f /tmp/antelopev2.zip
# InsightFace’ın doğru klasörü bulması için (isteğe bağlı)
ENV INSIGHTFACE_DIR=${INSIGHTFACE_MODELS_DIR}
# Install runpod
RUN pip install runpod requests

# Support for the network volume
ADD src/extra_model_paths.yaml ./

# Go back to the root
WORKDIR /

# Add scripts
ADD src/start.sh src/restore_snapshot.sh src/rp_handler.py test_input.json ./
RUN chmod +x /start.sh /restore_snapshot.sh

# Optionally copy the snapshot file
ADD *snapshot*.json /

# Restore the snapshot to install custom nodes
RUN /restore_snapshot.sh

# Start container
CMD ["/start.sh"]