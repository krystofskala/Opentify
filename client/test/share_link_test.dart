import 'package:flutter_test/flutter_test.dart';
import 'package:opentify_client/core/share_link.dart';

void main() {
  group('ShareLink – čisté formátování', () {
    test('prázdný vstup a vlastní skladba bez veřejného odkazu', () {
      const empty = ShareLink(url: null, title: '');
      expect(empty.primaryUrl, isNull);
      expect(empty.text, '');
      expect(empty.clipboardText, '');
      const own = ShareLink(url: null, title: 'Kontrast', artistName: 'Táta');
      expect(own.text, 'Kontrast – Táta');
      expect(own.clipboardText, '');
    });

    test('univerzální odkaz má přednost a služby mají stabilní pořadí', () {
      const link = ShareLink(
        url: 'https://song.link/a', title: 'Píseň', artistName: 'Žluťoučký',
        spotifyUrl: 'https://spotify.com/a', spotifySearchUrl: 'legacy',
        appleUrl: 'https://music.apple.com/a', youtubeUrl: 'https://youtu.be/a',
        soundcloudUrl: 'https://soundcloud.com/a',
      );
      const services = 'Spotify: https://spotify.com/a\n'
          'Apple Music: https://music.apple.com/a\n'
          'YouTube: https://youtu.be/a\nSoundCloud: https://soundcloud.com/a';
      expect(link.primaryUrl, 'https://song.link/a');
      expect(link.text, 'Píseň – Žluťoučký\n$services');
      expect(link.clipboardText, 'https://song.link/a\n$services');
    });

    test('YouTube a SoundCloud fallback se neopakuje ve schránce', () {
      const youtube = ShareLink(url: null, title: 'Video',
          youtubeUrl: 'https://youtu.be/a', soundcloudUrl: 'https://soundcloud.com/a');
      expect(youtube.primaryUrl, 'https://youtu.be/a');
      expect(youtube.clipboardText,
          'https://youtu.be/a\nSoundCloud: https://soundcloud.com/a');
      const soundcloud = ShareLink(url: null, title: 'Set', soundcloudUrl: 'https://soundcloud.com/a');
      expect(soundcloud.text, 'Set');
      expect(soundcloud.clipboardText, 'https://soundcloud.com/a');
    });

    test('vyhledávací odkazy se použijí při chybějících přímých odkazech', () {
      const link = ShareLink(url: null, title: 'Song',
          spotifySearchUrl: 'spotify-search', youtubeSearchUrl: 'youtube-search');
      expect(link.primaryUrl, isNull);
      expect(link.text, 'Song\nSpotify: spotify-search\nYouTube: youtube-search');
      expect(link.clipboardText, 'Spotify: spotify-search\nYouTube: youtube-search');
    });
  });
}
