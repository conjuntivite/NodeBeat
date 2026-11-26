import 'aba_stub.dart' if (dart.library.js_interop) 'aba_web.dart' as impl;

/// Abre o mapa em tela cheia noutra aba (no-op fora do navegador).
void abrirMapaEmNovaAba() => impl.abrirMapaEmNovaAba();

/// Aba em primeiro plano? Oculta, o mapa não consulta o servidor.
bool abaVisivel() => impl.abaVisivel();
