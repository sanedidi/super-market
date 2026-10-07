package uz.supermarket.sm_client

import com.yandex.mapkit.MapKitFactory
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Ключ MapKit — до регистрации плагинов.
        // Язык карты — язык приложения (Lang в sm_core хранит его в shared_preferences:
        // файл FlutterSharedPreferences, ключ flutter.sm_lang). Меняется со следующего запуска.
        val lang = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE).getString("flutter.sm_lang", "uz")
        MapKitFactory.setLocale(if (lang == "ru") "ru_RU" else "uz_UZ")
        // Ключ берётся из android/local.properties (yandex.mapkit.key), см. apps/README.md.
        MapKitFactory.setApiKey(BuildConfig.YANDEX_MAPKIT_KEY)
        super.configureFlutterEngine(flutterEngine)
    }
}
