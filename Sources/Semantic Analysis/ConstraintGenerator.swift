//
//  ConstraintGenerator.swift
//  trill
//
//  Created by Harlan Haskins on 4/11/17.
//  Copyright © 2017 Harlan. All rights reserved.
//

import Foundation

final class ConstraintGenerator: ASTTransformer {
  var goal: DataType = .error
  var env = ConstraintEnvironment()
  var system = ConstraintSystem()

  func reset(with env: ConstraintEnvironment) {
    self.goal = .error
    self.env = env
    self.system = ConstraintSystem()
  }

  func byBinding(_ name: Identifier, to type: DataType, _ f: () -> ()) {
    let oldEnv = env
    bind(name, to: type)
    f()
    env = oldEnv
  }

  func bind(_ name: Identifier, to type: DataType) {
    env[name] = type
  }

  // MARK: Monotypes

  override func visitVarExpr(_ expr: VarExpr) {
    if expr.isSelf {
      self.goal = expr.type
      return
    }

    if let t = env[expr.name] ?? context.global(named: expr.name)?.type {
      self.goal = t
      return
    }

    if let decl = expr.decl {
      self.goal = decl.type
      return
    }
  }

  override func visitSizeofExpr(_ expr: SizeofExpr) {
    self.goal = expr.type
  }

  override func visitPropertyRefExpr(_ expr: PropertyRefExpr) {
    visit(expr.lhs)
    let lhsGoal = self.goal
    system.constrainEqual(expr.typeDecl!, lhsGoal)

    let tau = env.freshTypeVariable()
    system.constrainEqual(expr.decl!, tau)

    self.goal = tau
  }

  override func visitVarAssignDecl(_ expr: VarAssignDecl) {
    let goalType: DataType

    // let <ident>: <Type> = <expr>
    if let e = expr.rhs {
      goalType = e.type
      byBinding(expr.name, to: goalType, {
        visit(e)
      })
      // Bind the given type to the goal type the initializer generated.
      system.constrainEqual(goalType, self.goal, node: e)

      if let typeRef = expr.typeRef {
        system.constrainEqual(e, typeRef.type)
      }
    }
      // let <ident> = <expr>
    else if let e = expr.rhs {
      // Generate
      let tau = env.freshTypeVariable()
      byBinding(expr.name, to: tau, {
        visit(e)
      })
      if let phi = ConstraintSolver(context: context)
                    .solveSystem(system) {
        goalType = tau.substitute(phi)
      } else {
        goalType = tau
      }
    } else {
      // let <ident>: <Type>
      // Take the type binding as fact and move on.
      goalType = expr.type
      bind(expr.name, to: goalType)
    }

    self.goal = goalType
  }

  override func visitFuncDecl(_ expr: FuncDecl) {
    if let body = expr.body {
      let oldEnv = self.env
      for p in expr.args {
        // Bind the type of the parameters.
        bind(p.name, to: p.type)
      }

      // Walk into the function body
      self.visit(body)
      self.env = oldEnv
    }
    self.goal = expr.type
  }

  override func visitFuncCallExpr(_ expr: FuncCallExpr) {
    visit(expr.lhs)
    let lhsGoal = self.goal
    var goals = [DataType]()
    if let pre = expr.lhs as? PropertyRefExpr {
      goals.append(pre.lhs.type)
    }
    for arg in expr.args {
      visit(arg.val)
      goals.append(self.goal)
    }
    let tau = env.freshTypeVariable()
    system.constrainEqual(lhsGoal,
                          .function(args: goals,
                                    returnType: tau,
                                    hasVarArgs: expr.decl!.hasVarArgs),
                          node: expr.lhs)
    goal = tau
  }

  override func visitIsExpr(_ expr: IsExpr) {
    let tau = env.freshTypeVariable()
    system.constrainEqual(expr, .bool)
    system.constrainEqual(expr.rhs, tau)
    goal = .bool
  }

  override func visitCoercionExpr(_ expr: CoercionExpr) {
    let tau = env.freshTypeVariable()
    system.constrainEqual(expr, tau)
    system.constrainEqual(expr.rhs, tau)
    goal = tau
  }

  override func visitInfixOperatorExpr(_ expr: InfixOperatorExpr) {
    let tau = env.freshTypeVariable()

    if expr.op.isAssign {
      goal = .void
      return
    }

    let lhsGoal = expr.decl!.type
    var goals = [DataType]()
    visit(expr.lhs)
    goals.append(goal)
    visit(expr.rhs)
    goals.append(goal)

    system.constrainEqual(lhsGoal,
                          .function(args: goals, returnType: tau,
                                    hasVarArgs: expr.decl!.hasVarArgs),
                          node: expr.lhs)
    goal = tau
  }

  override func visitSubscriptExpr(_ expr: SubscriptExpr) {
    visit(expr.lhs)
    var goals: [DataType] = [ self.goal ]
    expr.args.forEach { a in
      visit(a.val)
      goals.append(self.goal)
    }
    let tau = env.freshTypeVariable()
    if let decl = expr.decl {
      system.constrainEqual(decl, .function(args: goals, returnType: tau, hasVarArgs: false))
    }
    self.goal = tau
  }

  override func visitArrayExpr(_ expr: ArrayExpr) {
    guard case .array(_, let length) = expr.type else {
      fatalError("invalid array type")
    }
    let tau = env.freshTypeVariable()
    for value in expr.values {
      visit(value)
      system.constrainEqual(self.goal, tau, node: value)
    }
    let goal = DataType.array(field: tau, length: length)
    system.constrainEqual(expr, goal)
    self.goal = goal
  }

  override func visitTupleExpr(_ expr: TupleExpr) {
    var goals = [DataType]()
    for element in expr.values {
      visit(element)
      goals.append(self.goal)
    }
    system.constrainEqual(expr, .tuple(fields: goals))
    self.goal = expr.type
  }

  override func visitTernaryExpr(_ expr: TernaryExpr) {
    let tau = env.freshTypeVariable()

    visit(expr.condition)
    system.constrainEqual(expr.condition, .bool)

    visit(expr.trueCase)
    system.constrainEqual(expr.trueCase, tau)

    visit(expr.falseCase)
    system.constrainEqual(expr.falseCase, tau)

    system.constrainEqual(expr, tau)

    self.goal = tau
  }

  override func visitPrefixOperatorExpr(_ expr: PrefixOperatorExpr) {
    visit(expr.rhs)
    let rhsGoal = self.goal
    switch expr.op {
    case .ampersand:
      goal = .pointer(type: rhsGoal)
    case .bitwiseNot:
      goal = rhsGoal
    case .minus:
      goal = rhsGoal
    case .not:
      goal = .bool
      system.constrainEqual(rhsGoal, .bool, node: expr.rhs)
    case .star:
      guard case .pointer(let element) = expr.rhs.type else {
        fatalError("invalid dereference?")
      }
      goal = element
    default:
      fatalError("invalid prefix operator: \(expr.op)")
    }
    system.constrainEqual(expr, goal)
  }

  override func visitTupleFieldLookupExpr(_ expr: TupleFieldLookupExpr) {
    visit(expr.lhs)
    let lhsGoal = self.goal

    system.constrainEqual(expr.decl!, lhsGoal)
    let tau = env.freshTypeVariable()

    system.constrainEqual(expr, tau)
    self.goal = tau
  }

  override func visitParenExpr(_ expr: ParenExpr) {
    visit(expr.value)
    self.goal = expr.type
  }

  override func visitTypeRefExpr(_ expr: TypeRefExpr) {
    self.goal = expr.type
  }

  override func visitPoundFunctionExpr(_ expr: PoundFunctionExpr) {
    visitStringExpr(expr)
  }

  override func visitClosureExpr(_ expr: ClosureExpr) {
    // TODO: Implement this
  }

  // MARK: Literals

  override func visitNumExpr(_ expr: NumExpr) { self.goal = expr.type }
  override func visitCharExpr(_ expr: CharExpr) { self.goal = expr.type }
  override func visitFloatExpr(_ expr: FloatExpr) { self.goal = expr.type }
  override func visitBoolExpr(_ expr: BoolExpr) { self.goal = expr.type }
  override func visitVoidExpr(_ expr: VoidExpr) { self.goal = expr.type }
  override func visitNilExpr(_ expr: NilExpr) { self.goal = expr.type }
  override func visitStringExpr(_ expr: StringExpr) { self.goal = expr.type }
}
