import 'package:powersync/powersync.dart';
import 'config.dart';

final schema = Schema(([
  Table('lww', [Column.text('id'), Column.integer('k'), Column.text('v')],
      indexes: [
        Index('lww_id', [IndexedColumn('id')]),
        Index('lww_k', [IndexedColumn('k')])
      ],
      localOnly: bool.parse(config['LOCAL_ONLY'] ?? 'false'))
]));
