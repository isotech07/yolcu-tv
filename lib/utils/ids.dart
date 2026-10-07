/// Uygulama yeniden başlasa da aynı kalan kimlik üretir (FNV-1a 64 bit).
/// Dart'ın String.hashCode değeri çalıştırmalar arasında garanti değildir,
/// favoriler ve son izlenenler kaybolmasın diye bunu kullanıyoruz.
String stableId(String input) {
  var hash = 0xcbf29ce484222325;
  const prime = 0x100000001b3;
  for (final unit in input.codeUnits) {
    hash ^= unit;
    hash = hash * prime; // 64 bit taşma bilerek kullanılıyor
  }
  return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}

/// Yeni kayıtlar (liste vb.) için benzersiz kimlik.
String newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

String? nonEmpty(Object? value) {
  if (value == null) return null;
  final s = value.toString().trim();
  return s.isEmpty ? null : s;
}
