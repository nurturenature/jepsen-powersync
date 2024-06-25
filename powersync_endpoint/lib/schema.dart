import 'package:powersync/powersync.dart';
import 'config.dart';

final schema = Schema(([
  Table('lww', [Column.integer('k'), Column.text('v')],
      indexes: [
        Index('lww_k', [IndexedColumn('k')])
      ],
      localOnly: bool.parse(config['LOCAL_ONLY'] ?? 'false'))
]));
