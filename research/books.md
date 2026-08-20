# Online books (free)

All free to read online; verified at curation time (2026-08-20). These are the ones the architect's spec/arch work will be grounded in.

## Must-read for this project

**Neural Networks and Deep Learning — Michael A. Nielsen (2015)**
- https://neuralnetworksanddeeplearning.com/ (chapters: https://neuralnetworksanddeeplearning.com/chap1.html … chap6)
- Free online, CC BY-NC 3.0. Code: https://github.com/mnielsen/neural-networks-and-deep-learning
- **Why:** the clearest treatment of exactly what a learning accelerator computes — perceptrons & sigmoid neurons (ch. 1), gradient descent / stochastic gradient descent (ch. 1–2), backpropagation (ch. 2), softmax + cross-entropy (ch. 3). MNIST is the running example throughout — matches our dataset feed.
- Read: ch. 1 (neurons + SGD), ch. 2 (backprop), ch. 3 (improving learning). The math here is the spec for the RTL datapath.

**Deep Learning — Goodfellow, Bengio, Courville (2016, MIT Press)**
- https://mitpress.ublish.com/book/deep-learning — free online; PDF: https://aikosh.indiaai.gov.in/static/Deep+Learning+Ian+Goodfellow.pdf ; official site: https://www.deeplearningbook.org
- **Why:** the authoritative reference. Ch. 5.9 (Stochastic Gradient Descent) is the formal statement of online/mini-batch SGD; ch. 6 (deep feedforward nets) formalizes the layers/activations; ch. 8 (optimization) covers learning rates and convergence — the source for any "why does the update rule look like this" question during architecture review.

**Understanding Machine Learning: From Theory to Algorithms — Shai Shalev-Shwartz & Shai Ben-David (2014, Cambridge UP)**
- https://www.cs.huji.ac.il/~shais/UnderstandingMachineLearning/ (free PDF, CC BY-NC-SA); open-tech-book listing: https://opentechbook.com/book/understanding-machine-learning/
- **Why:** **ch. 21 = Online Learning** — the formal theory of learning from a stream of samples (regret bounds, online convex optimization, Perceptron/online gradient descent). The IP concept ("fed by online datasets") is literally this chapter in hardware. Ch. 20 (neural networks) gives the perceptron/backprop formalization.

## Reference / background

- **Parallel Programming for FPGAs** (Kastner, Matai, Neuendorffer — free online) — FPGA datapath/architecture patterns. *(Not yet fetched this session — add link on next pass.)*
- **From Tiny Machine Learning to Tiny Deep Learning: A Survey** (JACM 2025) — see papers.md §3; serves as the "state of the art in 2025" book-length overview of tiny on-device learning.

## Reading notes (for the architect brief)

| Concept | Book/source | Why the RTL needs it |
|---|---|---|
| Perceptron / sigmoid neuron | Nielsen ch.1 | The basic compute unit (MAC + activation) |
| Stochastic gradient descent | Nielsen ch.1, UML ch.21, Goodfellow 5.9 | The weight-update rule = the "learning" in the accelerator |
| Backpropagation | Nielsen ch.2, Goodfellow ch.6 | Required if the IP has ≥2 trainable layers |
| Softmax + cross-entropy | Nielsen ch.3 | Classification experiments on MNIST-class data |
| Online learning theory (regret, OGD) | UML ch.21 | Justifies/chooses the update rule; streaming-samples model |
| Fixed-point training | FPL/IJCAI/TCAD papers (papers.md §1) | 16-bit fixed point is the proven training precision |
