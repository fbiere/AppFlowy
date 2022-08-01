import 'package:flowy_editor/document/attributes.dart';
import 'package:flowy_editor/flowy_editor.dart';

abstract class Operation {
  factory Operation.fromJson(Map<String, dynamic> map) {
    String t = map["type"] as String;
    if (t == "insert-operation") {
      final path = map["path"] as List<int>;
      final value = Node.fromJson(map["value"]);
      return InsertOperation(path: path, value: value);
    }

    throw ArgumentError('unexpected type $t');
  }
  final Path path;
  Operation({required this.path});
  Operation copyWithPath(Path path);
  Operation invert();
  Map<String, dynamic> toJson();
}

class InsertOperation extends Operation {
  final Node value;

  InsertOperation({
    required super.path,
    required this.value,
  });

  InsertOperation copyWith({Path? path, Node? value}) =>
      InsertOperation(path: path ?? this.path, value: value ?? this.value);

  @override
  Operation copyWithPath(Path path) => copyWith(path: path);

  @override
  Operation invert() {
    return DeleteOperation(
      path: path,
      removedValue: value,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "insert-operation",
      "path": path.toList(),
      "value": value.toJson(),
    };
  }
}

class UpdateOperation extends Operation {
  final Attributes attributes;
  final Attributes oldAttributes;

  UpdateOperation({
    required super.path,
    required this.attributes,
    required this.oldAttributes,
  });

  UpdateOperation copyWith(
          {Path? path, Attributes? attributes, Attributes? oldAttributes}) =>
      UpdateOperation(
          path: path ?? this.path,
          attributes: attributes ?? this.attributes,
          oldAttributes: oldAttributes ?? this.oldAttributes);

  @override
  Operation copyWithPath(Path path) => copyWith(path: path);

  @override
  Operation invert() {
    return UpdateOperation(
      path: path,
      attributes: oldAttributes,
      oldAttributes: attributes,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "update-operation",
      "path": path.toList(),
      "attributes": {...attributes},
      "oldAttributes": {...oldAttributes},
    };
  }
}

class DeleteOperation extends Operation {
  final Node removedValue;

  DeleteOperation({
    required super.path,
    required this.removedValue,
  });

  DeleteOperation copyWith({Path? path, Node? removedValue}) => DeleteOperation(
      path: path ?? this.path, removedValue: removedValue ?? this.removedValue);

  @override
  Operation copyWithPath(Path path) => copyWith(path: path);

  @override
  Operation invert() {
    return InsertOperation(
      path: path,
      value: removedValue,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "delete-operation",
      "path": path.toList(),
      "removedValue": removedValue.toJson(),
    };
  }
}

class TextEditOperation extends Operation {
  final Delta delta;
  final Delta inverted;

  TextEditOperation({
    required super.path,
    required this.delta,
    required this.inverted,
  });

  TextEditOperation copyWith({Path? path, Delta? delta, Delta? inverted}) =>
      TextEditOperation(
          path: path ?? this.path,
          delta: delta ?? this.delta,
          inverted: inverted ?? this.inverted);

  @override
  Operation copyWithPath(Path path) => copyWith(path: path);

  @override
  Operation invert() {
    return TextEditOperation(path: path, delta: inverted, inverted: delta);
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "text-edit-operation",
      "path": path.toList(),
      "delta": delta.toJson(),
      "invert": inverted.toJson(),
    };
  }
}

Path transformPath(Path preInsertPath, Path b, [int delta = 1]) {
  if (preInsertPath.length > b.length) {
    return b;
  }
  if (preInsertPath.isEmpty || b.isEmpty) {
    return b;
  }
  // check the prefix
  for (var i = 0; i < preInsertPath.length - 1; i++) {
    if (preInsertPath[i] != b[i]) {
      return b;
    }
  }
  final prefix = preInsertPath.sublist(0, preInsertPath.length - 1);
  final suffix = b.sublist(preInsertPath.length);
  final preInsertLast = preInsertPath.last;
  final bAtIndex = b[preInsertPath.length - 1];
  if (preInsertLast <= bAtIndex) {
    prefix.add(bAtIndex + delta);
  } else {
    prefix.add(bAtIndex);
  }
  prefix.addAll(suffix);
  return prefix;
}

Operation transformOperation(Operation a, Operation b) {
  if (a is InsertOperation) {
    final newPath = transformPath(a.path, b.path);
    return b.copyWithPath(newPath);
  } else if (b is DeleteOperation) {
    final newPath = transformPath(a.path, b.path, -1);
    return b.copyWithPath(newPath);
  }
  // TODO: transform update and textedit
  return b;
}
