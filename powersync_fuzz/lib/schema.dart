import 'package:powersync/powersync.dart';

final schema = Schema(([
  Table('lww', [
    Column.integer('k'),
    Column.text('v')
  ], indexes: [
    Index('lww_k', [IndexedColumn('k')])
  ])
]));
