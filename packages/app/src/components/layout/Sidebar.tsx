import { NavLink } from "react-router-dom";
import { SpellCheck, History, UserCog, Settings } from "lucide-react";
import { cn } from "@/lib/utils";

const navItems = [
  { to: "/check", label: "Check Grammar", icon: SpellCheck },
  { to: "/history", label: "History", icon: History },
  { to: "/profiles", label: "Profiles", icon: UserCog },
  { to: "/settings", label: "Settings", icon: Settings },
];

export function Sidebar() {
  return (
    <aside className="flex h-full w-56 flex-col border-r bg-sidebar-background supports-[backdrop-filter]:backdrop-blur-xl supports-[backdrop-filter]:backdrop-saturate-150">
      <div className="px-4 pb-3 pt-10">
        <h1 className="text-base font-semibold text-sidebar-primary">Bex</h1>
      </div>
      <nav className="flex-1 space-y-1 px-2 pb-2">
        {navItems.map((item) => (
          <NavLink
            key={item.to}
            to={item.to}
            className={({ isActive }) =>
              cn(
                "flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium transition-colors",
                isActive
                  ? "bg-sidebar-accent text-sidebar-accent-foreground"
                  : "text-sidebar-foreground hover:bg-sidebar-accent hover:text-sidebar-accent-foreground",
              )
            }
          >
            <item.icon className="h-4 w-4" />
            {item.label}
          </NavLink>
        ))}
      </nav>
    </aside>
  );
}
