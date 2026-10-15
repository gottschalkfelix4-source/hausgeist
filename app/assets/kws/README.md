# Modell für das Aktivierungswort

`sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01` (int8) aus dem Projekt
[k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), Lizenz Apache-2.0.
Trainiert mit icefall auf GigaSpeech (englisch, 10 000 Stunden).

Quelle: https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2

Die Dateien sind unverändert und nur umbenannt. Die Silben (`tokens.txt`) muss der Server
genauso zerlegen: `backend/app/voice/kws_vocab.txt` stammt aus derselben `bpe.model`.
