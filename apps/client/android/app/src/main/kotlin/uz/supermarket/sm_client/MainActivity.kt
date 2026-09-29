package uz.supermarket.sm_client

import com.yandex.mapkit.MapKitFactory
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Ключ MapKit — до регистрации плагинов.
        MapKitFactory.setLocale("ru_RU")
        // Ключ берётся из android/local.properties (yandex.mapkit.key), см. apps/README.md.
        MapKitFactory.setApiKey(BuildConfig.YANDEX_MAPKIT_KEY)
        super.configureFlutterEngine(flutterEngine)
    }
}
