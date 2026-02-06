import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:intl/intl.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const EnCuentoQuedaApp());
}

// --- CAPA DE DATOS (SQLite) ---
class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  static Database? _database;
  static const String tablePorcentajes = 'porcentajes';
  static const String tableOfertas = 'ofertas';

  DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    String dbPath = join(await getDatabasesPath(), 'encuentoqueda_v4.db');
    return await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE $tablePorcentajes (id INTEGER PRIMARY KEY AUTOINCREMENT, valor INTEGER UNIQUE)',
        );
        await db.execute('''CREATE TABLE $tableOfertas (
        id INTEGER PRIMARY KEY AUTOINCREMENT, 
        precio_original REAL, 
        porcentaje INTEGER, 
        precio_final REAL, 
        ahorro REAL, 
        fecha TEXT)''');
        for (int i = 5; i <= 50; i += 5) {
          await db.insert(tablePorcentajes, {'valor': i});
        }
      },
    );
  }

  Future<void> insertPercentage(int v) async {
    final db = await database;
    await db.insert(tablePorcentajes, {
      'valor': v,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<int>> getAllPercentages() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      tablePorcentajes,
      orderBy: 'valor ASC',
    );
    return List.generate(maps.length, (i) => maps[i]['valor']);
  }

  Future<void> deletePercentage(int v) async {
    final db = await database;
    await db.delete(tablePorcentajes, where: 'valor = ?', whereArgs: [v]);
  }

  Future<void> restoreDefaults() async {
    final db = await database;
    await db.delete(tablePorcentajes);
    for (int i = 5; i <= 50; i += 5) {
      await db.insert(tablePorcentajes, {'valor': i});
    }
  }

  Future<void> insertOffer(double orig, int pct, double res, double save) async {
    final db = await database;
    await db.insert(tableOfertas, {
      'precio_original': orig,
      'porcentaje': pct,
      'precio_final': res,
      'ahorro': save,
      'fecha': DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now()),
    });
  }

  Future<List<Map<String, dynamic>>> getAllOffers() async {
    final db = await database;
    return await db.query(tableOfertas, orderBy: 'id DESC');
  }

  Future<void> deleteOffer(int id) async {
    final db = await database;
    await db.delete(tableOfertas, where: 'id = ?', whereArgs: [id]);
  }
}

// --- APP ---
class EnCuentoQuedaApp extends StatelessWidget {
  const EnCuentoQuedaApp({super.key});
  static const Color colorPrimario = Color(0xFFC06500); // El naranja profundo de la izquierda
  static const Color colorAcento = Color(0xFFFF9800);
 @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        // Cambio vital: El esquema de colores ahora nace de tu naranja institucional
        colorScheme: ColorScheme.fromSeed(
          seedColor: colorPrimario,
          primary: colorPrimario,
          secondary: colorAcento,
          surface: const Color(0xFFFFF8F1), // Un blanco hueso muy suave para el fondo
        ),
        useMaterial3: true,
        // Estilización global del AppBar para que coincida con tu diseño
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFFFF8F1),
          foregroundColor: colorPrimario, // Texto e iconos en naranja profundo
          elevation: 0,
          centerTitle: true,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final DatabaseHelper _db = DatabaseHelper();
  final TextEditingController _priceController = TextEditingController();
  final TextRecognizer _textRecognizer = TextRecognizer();
  final ScrollController _scrollController = ScrollController();

  CameraController? _cameraController;
  List<int> _porcentajes = [];
  double _currentZoom = 1.0;
  int? _selectedPct;
  double _finalPrice = 0.0;
  double _savings = 0.0;
  bool _isCameraReady = false;
  bool _successHighlight = false;

  @override
  void initState() {
    super.initState();
    _initApp();
    _priceController.addListener(_calculate);
  }

  void _initApp() async {
    await _checkPermissions();
    await _loadPorcentajes();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _cameraController?.dispose();
    _textRecognizer.close();
    _priceController.dispose();
    super.dispose();
  }

  void _scrollToIndex(int index, BuildContext context) {
    if (!_scrollController.hasClients) return;
    const double itemWidth = 80.0; 
    final double screenWidth = MediaQuery.of(context).size.width;
    double offset = (index * itemWidth) - (screenWidth / 2) + (itemWidth / 2);
    if (offset < 0) offset = 0;
    if (offset > _scrollController.position.maxScrollExtent) {
      offset = _scrollController.position.maxScrollExtent;
    }
    _scrollController.animateTo(
      offset,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOutCubic,
    );
  }

 Future<void> _checkPermissions() async {
  var status = await Permission.camera.status;

  // Si el usuario marcó "No volver a preguntar"
  if (status.isPermanentlyDenied) {
    openAppSettings(); // Abre la configuración del celular para habilitar manual
    return;
  }

  // Intento de solicitud estándar
  if (await Permission.camera.request().isGranted) {
    final cameras = await availableCameras();
    if (cameras.isNotEmpty) {
      _cameraController = CameraController(
        cameras[0],
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await _cameraController?.initialize();
      if (mounted) setState(() => _isCameraReady = true);
    }
  } else {
    // Si vuelve a denegar, nos aseguramos que el estado refleje que no está lista
    if (mounted) setState(() => _isCameraReady = false);
  }
}
  Future<void> _loadPorcentajes() async {
    final data = await _db.getAllPercentages();
    if (mounted) setState(() => _porcentajes = data);
  }

void _calculate() {
  // PASO 1: SANITIZACIÓN CRÍTICA PARA CLP
  // Obtenemos el texto del controlador. Si el usuario ingresó puntos (ej: "29.990"),
  // los eliminamos para que el sistema entienda que es "29990" y no "29 coma 990".
  String cleanText = _priceController.text.replaceAll('.', '');

  // PASO 2: PARSEO SEGURO
  // Ahora convertimos la cadena limpia a un número decimal.
  double original = double.tryParse(cleanText) ?? 0.0;

  // Límites de negocio (Legacy preservado)
  if (original < 0) original = 0;
  if (original > 100000000) original = 100000000;

  if (_selectedPct != null) {
    setState(() {
      // PASO 3: CORRECCIÓN MATEMÁTICA (El arreglo del peso extra)

      // a) Calculamos el monto matemático exacto del descuento
      // Ej: 29990 * 15 / 100 = 4498.5
      double exactDiscountAmount = original * _selectedPct! / 100;

      // b) FIX QUIRÚRGICO: Redondeamos el ahorro al entero más cercano PRIMERO.
      // Usamos .roundToDouble() para aplicar el redondeo estándar (ej: 4498.5 -> 4499.0)
      // Esta se convierte en nuestra "fuente de la verdad" para el ahorro.
      _savings = exactDiscountAmount.roundToDouble();

      // c) Calculamos el precio final basándonos en el ahorro ya redondeado.
      // Esto garantiza matemáticamente que: Final + Ahorro = Original.
      // Ej: 29990 - 4499 = 25491
      _finalPrice = original - _savings;
    });
  }
}





  Future<void> _scanPrice(BuildContext context) async {

    if (!_isCameraReady || _cameraController == null || !_cameraController!.value.isInitialized) {
    // Si no está lista, enviamos el mensaje al usuario
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Cámara no disponible. Por favor, otorga los permisos en el visor superior."),
        backgroundColor: Colors.redAccent,
        duration: Duration(seconds: 3),
        behavior: SnackBarBehavior.floating, // Se ve más moderno
      ),
    );
    return; // Abortamos la ejecución quirúrgicamente
  }

    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    try {
      final image = await _cameraController!.takePicture();
      final recognizedText = await _textRecognizer.processImage(InputImage.fromFilePath(image.path));
      RegExp regExp = RegExp(r"\$\s*(\d+[\.,]?\d*)|(\d+[\.,]?\d*)\s*\$");
      var match = regExp.firstMatch(recognizedText.text);
      if (match != null && mounted) {
        String rawNumbers = match.group(0)!.replaceAll(RegExp(r'[^\d]'), '');
        int parsedPrice = int.tryParse(rawNumbers) ?? 0;
        if (parsedPrice > 100000000) parsedPrice = 100000000;
        setState(() {
    _priceController.text = NumberFormat.currency(locale: 'es_CL', symbol: '', decimalDigits: 0).format(parsedPrice).trim();
  _successHighlight = true;
        });
        Future.delayed(const Duration(seconds: 2), () => setState(() => _successHighlight = false));
      } else {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("No se pudo capturar el precio"), backgroundColor: Colors.orange));
      }
    } catch (e) { debugPrint("OCR Error: $e"); }
  }


  @override
  Widget build(BuildContext context) {
    final clpFormater = NumberFormat.currency(locale: 'es_CL', symbol: '', decimalDigits: 0);
    final size = MediaQuery.of(context).size;



    return Scaffold(
      // FIX QUIRÚRGICO: Mantiene la UI estable cuando sube el teclado
      resizeToAvoidBottomInset: false, 
      appBar: AppBar(
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text("EnCuantoQueda 1.0",style: TextStyle(color: Colors.white),), centerTitle: true, backgroundColor:EnCuentoQuedaApp.colorPrimario),
      drawer: _buildDrawer(context),
      body: SafeArea(
        child: Column(
          children: [
            // --- SECCIÓN FIJA (BANNER PUBLICITARIO) ---
            Container(
              height: 55,
              width: double.infinity,
              color: const Color.fromARGB(255, 212, 158, 77),
              alignment: Alignment.center,
              child: const Text(
                "Escanea el precio",
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),

            // --- SECCIÓN SCROLLABLE (CONTENIDO DINÁMICO) ---
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Column(
                    children: [
                      _buildVisor(size),
                      const SizedBox(height: 20),
                      ElevatedButton.icon(
                        onPressed: () => _scanPrice(context),
                        icon: const Icon(Icons.document_scanner),
                        label: const Text("CAPTURAR PRECIO (\$)"),
                      ),
                      const SizedBox(height: 25),
                      _buildInputPrecio(),
                      const SizedBox(height: 25),
                      Text("Selecciona el % de descuento:", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.grey[700])),
                      const SizedBox(height: 10),
                      _buildCarrusel(context),
                      const SizedBox(height: 25),
                      if (_selectedPct != null) ...[
                        Text("Precio Final: \$ ${clpFormater.format(_finalPrice)}", style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.green)),
                        Text("Ahorro: \$${clpFormater.format(_savings)}", style: const TextStyle(fontSize: 18, color: Colors.blueGrey)),
                        const SizedBox(height: 20),
                        ElevatedButton.icon(onPressed: () => _saveOffer(context), icon: const Icon(Icons.save), label: const Text("GUARDAR DESCUENTO")),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- WIDGETS DE APOYO (LEGACY PRESERVADO) ---

  Widget _buildVisor(Size size) {
    return Center(
      child: Container(
        height: size.height * 0.25,
        width: size.width * 0.9,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.indigo.shade100, width: 1.5),
          boxShadow: [BoxShadow(color: Colors.indigo.withOpacity(0.15), blurRadius: 15, offset: const Offset(0, 8), spreadRadius: 1)],
        ),
        child: Row(
          children: [
           // Lado izquierdo: Cámara con su propio recorte redondeado
SizedBox(
  width: (size.width * 0.9) * 0.75,
  child: ClipRRect(
    borderRadius: const BorderRadius.only(
      topLeft: Radius.circular(16),
      bottomLeft: Radius.circular(16),
    ),
    child: _isCameraReady
        ? CameraPreview(_cameraController!)
        : Container(
            color: Colors.blueGrey[900],
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.videocam_off_outlined, color: Colors.white54, size: 40),
                const SizedBox(height: 8),
                const Text(
                  "Cámara deshabilitada",
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
                TextButton(
                  onPressed: _checkPermissions, // Re-lanza la solicitud
                  child: const Text(
                    "OTORGAR PERMISOS",
                    style: TextStyle(
                      color: Colors.blueAccent,
                      fontWeight: FontWeight.bold,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ],
            ),
          ),
  ),
),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.zoom_in, size: 20, color: Colors.indigo[700]),
                  Expanded(
                    child: RotatedBox(
                      quarterTurns: 3,
                      child: SliderTheme(
                        data: SliderThemeData(activeTrackColor: Colors.indigo[700], inactiveTrackColor: Colors.indigo[100], thumbColor: Colors.indigo),
                        child: Slider(value: _currentZoom, min: 1.0, max: 8.0, onChanged: (v) { setState(() => _currentZoom = v); _cameraController?.setZoomLevel(v); }),
                      ),
                    ),
                  ),
                  Icon(Icons.zoom_out, size: 20, color: Colors.indigo[700]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputPrecio() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 30),
      child: TextField(
        controller: _priceController,
        keyboardType: TextInputType.number,
        inputFormatters: [ClpInputFormatter()],
        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Color(0xFF2D3142)),
        decoration: InputDecoration(
          labelText: "Precio del producto",
          prefixText: "\$ ",
          prefixStyle: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: const Color.fromARGB(255, 33, 34, 34)),
          suffixIcon: IconButton(icon: const Icon(Icons.close, size: 28, color: Colors.orange, ), onPressed: () => _priceController.clear()),
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide(color: _successHighlight ? Colors.green : Colors.orange.withOpacity(0.2), width: _successHighlight ? 3 : 1.5)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: const BorderSide(color: Colors.orange, width: 2)),
          floatingLabelBehavior: FloatingLabelBehavior.always,
        ),
      ),
    );
  }

  Widget _buildCarrusel(BuildContext context) {
    return Container(
      height: 100,
      child: ListView.builder(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        itemCount: _porcentajes.length + 1,
        itemBuilder: (ctx, index) {
          if (index == _porcentajes.length) return _buildAddBtn(context);
          int val = _porcentajes[index];
          return GestureDetector(
            onTap: () {
              setState(() => _selectedPct = val);
              _calculate();
              _scrollToIndex(index, context);
            },
            child: _buildCircle(val, index, context),
          );
        },
      ),
    );
  }

  Widget _buildCircle(int pct, int index, BuildContext context) {
    final bool isSelected = _selectedPct == pct;
    final double size = isSelected ? 80.0 : 60.0;
    return RepaintBoundary(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutBack,
        width: size,
        height: size,
        margin: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isSelected ? const Color(0xFF2ECC71) : Colors.blue,
          border: isSelected ? Border.all(color: Colors.white.withOpacity(0.6), width: 4) : null,
          boxShadow: [BoxShadow(color: isSelected ? const Color(0xFF2ECC71).withOpacity(0.4) : Colors.transparent, blurRadius: 15.0, spreadRadius: isSelected ? 2.0 : 0.0)],
        ),
        child: Text("$pct%", style: TextStyle(color: Colors.white, fontSize: isSelected ? 22 : 16, fontWeight: FontWeight.bold)),
      ),
    );
  }

 Future<void> _saveOffer(BuildContext context) async {
  // 1. Obtenemos el texto y limpiamos espacios
  final String rawText = _priceController.text.trim();

  // 2. Validación de presencia
  if (rawText.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Ingresa un precio primero"), backgroundColor: Colors.redAccent)
    );
    return;
  }

  // 3. LIMPIEZA QUIRÚRGICA: Eliminamos los puntos de miles antes de parsear
  // Esto permite que "2.222.222" pase a ser "2222222"
  final String cleanText = rawText.replaceAll('.', '');
  final double? original = double.tryParse(cleanText);

  // 4. Validación de selección de porcentaje
  if (_selectedPct == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Selecciona un descuento"), backgroundColor: Colors.orange)
    );
    return;
  }

  // 5. Persistencia si el número es válido
  if (original != null && original > 0) {
    await _db.insertOffer(
      original, 
      _selectedPct!, 
      _finalPrice, 
      _savings
    );

    if (!mounted) return;
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("¡Descuento guardado!"))
    );
  } else {
    // Si llegara a fallar el parseo por alguna razón, ahora sí damos feedback
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Error: El formato del precio no es válido"), backgroundColor: Colors.red)
    );
  }
}

  Widget _buildDrawer(BuildContext context) {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          const DrawerHeader(decoration: BoxDecoration(color: EnCuentoQuedaApp.colorPrimario), child: Column(
            children: [
              Center(child: Text("EnCuantoQueda 1.0", style: TextStyle(color: Colors.white, fontSize: 24))),
              SizedBox(height: 10),
              Center(child: Text("Calcula y guarda tus descuentos fácilmente. By @chalalo", style: TextStyle(color: Colors.white, fontSize: 14)))
            ],
          )),
          ListTile(leading: const Icon(Icons.save), title: const Text("Ofertas Guardadas"), onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (c) => const SavedOffersScreen())); }),
          ListTile(leading: const Icon(Icons.settings), title: const Text("Gestionar Porcentajes"), onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (c) => const PercentagesScreen())); }),
        ],
      ),
    );
  }

  Widget _buildAddBtn(BuildContext context) {
    return InkWell(
      onTap: () => _showAddDialog(context),
      child: Container(width: 60, margin: const EdgeInsets.symmetric(horizontal: 6), decoration: BoxDecoration(border: Border.all(color: Colors.blue, width: 2), shape: BoxShape.circle), child: const Icon(Icons.add, color: Colors.blue)),
    );
  }

  void _showAddDialog(BuildContext context) {
    final c = TextEditingController();
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text("Nuevo %"),
      content: TextField(controller: c, keyboardType: TextInputType.number, decoration: const InputDecoration(hintText: "Rango 0-100")),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR")),
        TextButton(onPressed: () async {
          int? val = int.tryParse(c.text);
          if (val != null && val >= 0 && val <= 100) {
            await _db.insertPercentage(val);
            _loadPorcentajes();
            Navigator.pop(ctx);
          } else {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Porcentaje inválido (0-100)")));
          }
        }, child: const Text("OK")),
      ],
    ));
  }
}

// --- PANTALLAS DE SOPORTE (LEGACY) ---

class SavedOffersScreen extends StatefulWidget {
  const SavedOffersScreen({super.key});
  @override
  State<SavedOffersScreen> createState() => _SavedOffersScreenState();
}

class _SavedOffersScreenState extends State<SavedOffersScreen> {
  final _db = DatabaseHelper();
  List<Map<String, dynamic>> _offers = [];

  @override
  void initState() { super.initState(); _refresh(); }
  void _refresh() async { final data = await _db.getAllOffers(); setState(() => _offers = data); }

@override
Widget build(BuildContext context) {
  // AJUSTE QUIRÚRGICO: Quitamos el símbolo del formateador para controlarlo manualmente
  final clp = NumberFormat.currency(locale: 'es_CL', symbol: '', decimalDigits: 0);

  return Scaffold(
    appBar: AppBar(
      iconTheme: const IconThemeData(color: Colors.white),
      title: const Text("Ofertas Guardadas", style: TextStyle(color: Colors.white)),
      centerTitle: true,
      backgroundColor: EnCuentoQuedaApp.colorPrimario,
    ),
    body: _offers.isEmpty 
      ? const Center(child: Text("No hay ofertas guardadas.")) 
      : ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 10),
          itemCount: _offers.length,
          itemBuilder: (ctx, i) {
            final o = _offers[i];
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 4)),
                ],
              ),
              child: IntrinsicHeight(
                child: Row(
                  children: [
                    Container(
                      width: 6,
                      decoration: const BoxDecoration(
                        color: EnCuentoQuedaApp.colorPrimario,
                        borderRadius: BorderRadius.only(topLeft: Radius.circular(12), bottomLeft: Radius.circular(12)),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                // FIX: Símbolo $ a la izquierda del número
                                Text(
                                  "Final: \$ ${clp.format(o['precio_final']).trim()}",
                                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.green),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(color: Colors.green.shade50, borderRadius: BorderRadius.circular(20)),
                                  child: Text("${o['porcentaje']}% OFF", style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 12)),
                                ),
                              ],
                            ),
                            const Divider(height: 20),
                            // FIX: Aplicamos el símbolo a la izquierda también en los detalles
                            Text("Precio Original: \$ ${clp.format(o['precio_original']).trim()}", style: TextStyle(color: Colors.grey[800], fontSize: 14)),
                            const SizedBox(height: 4),
                            Text("Ahorro Real: \$ ${clp.format(o['ahorro']).trim()}", style: const TextStyle(color: EnCuentoQuedaApp.colorPrimario, fontWeight: FontWeight.bold, fontSize: 14)),
                            const SizedBox(height: 12),
                            // FIX: Fecha con contraste máximo (black87) para nitidez total
                            Row(
                              children: [
                                Icon(Icons.access_time, size: 14, color: Colors.blueGrey[800]),
                                const SizedBox(width: 6),
                                Text(
                                  o['fecha'], 
                                  style: TextStyle(
                                    color: Colors.black87, // Color sólido para evitar efecto borroso
                                    fontSize: 13, 
                                    fontWeight: FontWeight.w600, 
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                      onPressed: () => _confirmDelete(o['id'], context),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
  );
}

  void _confirmDelete(int id, BuildContext context) {
    showDialog(context: context, builder: (ctx) => AlertDialog(title: const Text("Confirmar"), content: const Text("¿Eliminar oferta?"), actions: [
      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR")),
      TextButton(onPressed: () async { await _db.deleteOffer(id); _refresh(); Navigator.pop(ctx); }, child: const Text("ELIMINAR", style: TextStyle(color: Colors.red))),
    ]));
  }
}

class PercentagesScreen extends StatefulWidget {
  const PercentagesScreen({super.key});
  @override
  State<PercentagesScreen> createState() => _PercentagesScreenState();
}

class _PercentagesScreenState extends State<PercentagesScreen> {
  final DatabaseHelper _db = DatabaseHelper();
  List<int> _list = [];
  @override
  void initState() { super.initState(); _refresh(); }
  Future<void> _refresh() async { final data = await _db.getAllPercentages(); if (mounted) setState(() => _list = data); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(

      //  appBar: AppBar(
      //   iconTheme: const IconThemeData(color: Colors.white),
      //   title: const Text("EnCuentoQueda 1.0",style: TextStyle(color: Colors.white),), centerTitle: true, backgroundColor:EnCuentoQuedaApp.colorPrimario),
      appBar: AppBar(
         iconTheme: const IconThemeData(color: Colors.white),
         backgroundColor:EnCuentoQuedaApp.colorPrimario,
        title: const Text("Porcentajes",style: TextStyle(color: Colors.white)), actions: [
        IconButton(icon: const Icon(Icons.add), onPressed: () => _showAddDialog(context)),
        IconButton(icon: const Icon(Icons.restore), onPressed: () => _confirmRestore(context)),
      ]),
      body: ListView.builder(itemCount: _list.length, itemBuilder: (ctx, i) => ListTile(leading: const Icon(Icons.percent, color: Colors.orange), title: Text("${_list[i]}% de descuento"), trailing: IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red), onPressed: () => _confirmDelete(_list[i], context)))),
    );
  }

  void _confirmDelete(int val, BuildContext context) {
    showDialog(context: context, builder: (ctx) => AlertDialog(title: const Text("¿Eliminar?"), actions: [
      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR")),
      TextButton(onPressed: () async { await _db.deletePercentage(val); _refresh(); Navigator.pop(ctx); }, child: const Text("SÍ")),
    ]));
  }

  void _confirmRestore(BuildContext context) {
    showDialog(context: context, builder: (ctx) => AlertDialog(title: const Text("Restaurar"), actions: [
      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("NO")),
      TextButton(onPressed: () async { await _db.restoreDefaults(); _refresh(); Navigator.pop(ctx); }, child: const Text("SÍ")),
    ]));
  }

  void _showAddDialog(BuildContext context) {
    final c = TextEditingController();
    showDialog(context: context, builder: (ctx) => AlertDialog(title: const Text("Nuevo %"), content: TextField(controller: c, keyboardType: TextInputType.number), actions: [
      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR")),
      TextButton(onPressed: () async { await _db.insertPercentage(int.tryParse(c.text) ?? 0); _refresh(); Navigator.pop(ctx); }, child: const Text("OK")),
    ]));
  }


  
}


class ClpInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.text.isEmpty) return newValue;
    // Eliminamos todo lo que no sea número
    String digits = newValue.text.replaceAll(RegExp(r'[^\d]'), '');
    int value = int.tryParse(digits) ?? 0;
    
    // Aplicamos el límite de 100.000.000
    if (value > 100000000) value = 100000000;
    
    // Formateamos con puntos
    final String newText = NumberFormat.currency(locale: 'es_CL', symbol: '', decimalDigits: 0).format(value).trim();
    
    return newValue.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: newText.length),
    );
  }
}