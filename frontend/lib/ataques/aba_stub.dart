// Fora do navegador (testes na VM).
void abrirMapaEmNovaAba() {}
bool abaVisivel() => true;

String? _tema;
String? temaTvSalvo() => _tema;
void salvarTemaTv(String tema) => _tema = tema;

String? _paleta;
String? paletaTvSalva() => _paleta;
void salvarPaletaTv(String id) => _paleta = id;
