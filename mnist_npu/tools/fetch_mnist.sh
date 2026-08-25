#!/bin/sh
# fetch_mnist.sh — download MNIST (train 60k + test 10k) from the PyTorch
# S3 mirror (ossci-datasets). Output: data/*.gz (gitignored, regenerable).
set -e
cd "$(dirname "$0")/.."
mkdir -p data
BASE=https://ossci-datasets.s3.amazonaws.com/mnist
for f in train-images-idx3-ubyte.gz train-labels-idx1-ubyte.gz \
         t10k-images-idx3-ubyte.gz t10k-labels-idx1-ubyte.gz; do
    [ -f "data/$f" ] || curl -sS -o "data/$f" "$BASE/$f"
done
ls -la data/
