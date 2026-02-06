import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  static Database? _database;

  // Nombres de tablas
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
    String path = join(await getDatabasesPath(), 'encuentoqueda.db');
    return await openDatabase(
      path,
      version: 1, 
      onCreate: (db, version) async {
        // Tabla de Porcentajes
        await db.execute('''
          CREATE TABLE $tablePorcentajes (
            id INTEGER PRIMARY KEY AUTOINCREMENT, 
            valor INTEGER UNIQUE
          )
        ''');
        
        // Tabla de Ofertas (Historial)
        await db.execute('''
          CREATE TABLE $tableOfertas (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            precio_original REAL,
            porcentaje INTEGER,
            precio_final REAL,
            fecha TEXT
          )
        ''');
      },
    );
  }

  // --- MÉTODOS PARA PORCENTAJES ---

  Future<int> insertPercentage(int valor) async {
    final db = await database;
    return await db.insert(tablePorcentajes, {'valor': valor}, 
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<int>> getAllPercentages() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(tablePorcentajes, orderBy: 'valor ASC');
    return List.generate(maps.length, (i) => maps[i]['valor']);
  }

  Future<void> deletePercentage(int valor) async {
    final db = await database;
    await db.delete(tablePorcentajes, where: 'valor = ?', whereArgs: [valor]);
  }

  Future<void> restoreDefaultPercentages() async {
    final db = await database;
    await db.delete(tablePorcentajes);
    List<int> defaults = [5, 10, 15, 20, 25, 30, 35, 40, 45, 50];
    for (var v in defaults) {
      await insertPercentage(v);
    }
  }

  // --- MÉTODOS PARA OFERTAS ---

  Future<int> insertOffer(double original, int pct, double result) async {
    final db = await database;
    return await db.insert(tableOfertas, {
      'precio_original': original,
      'porcentaje': pct,
      'precio_final': result,
      'fecha': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Map<String, dynamic>>> getAllOffers() async {
    final db = await database;
    return await db.query(tableOfertas, orderBy: 'fecha DESC');
  }

  Future<void> clearOffers() async {
    final db = await database;
    await db.delete(tableOfertas);
  }
}